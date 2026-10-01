-- ============================================================================
-- ยื่นต่ออายุล่วงหน้าได้ 5 เดือน — 2026-10-01 (ผู้ใช้สั่ง · เดิม 30 วัน)
--
--   รถที่มีกรมธรรม์ในระบบ → ยื่นต่ออายุได้ตั้งแต่ "วันหมดอายุ − 5 เดือน" (นับเดือนตามปฏิทิน)
--     เช่น หมด 30 ก.ย. 2570 → ยื่นได้ตั้งแต่ 30 เม.ย. 2570 · ก่อนหน้านั้นฟอร์มขึ้นว่ายื่นได้ตั้งแต่วันไหน
--
--   🐞 แก้ไปด้วย: "กรมธรรม์ในระบบ" เดิมดูแค่ Excel (ins_active_policy)
--      → รถที่ต่อประกันผ่านระบบนี้ ปีหน้าตัวเช็คไม่รู้ว่ามีกรมธรรม์ ไม่มีด่านต่ออายุเลย
--      ตอนนี้ดู 2 แหล่งเหมือนแถบต่ออายุ (migrate-2026-09-30-renewal-v2): Excel + ใบที่ปิดการขาย
--      รถคันเดียวกันใช้เล่มที่หมดล่าสุด (ต่อแล้ว = นับจากเล่มใหม่)
--
--   ฟอร์ม (index.html) อ่านวันที่จากผลของฟังก์ชันนี้อยู่แล้ว ไม่ต้องแก้หน้าเว็บ
--   ins_submit เรียกฟังก์ชันนี้ซ้ำตอนส่ง → กติกาใหม่มีผลทั้งหน้าฟอร์มและฝั่งเซิร์ฟเวอร์ทันที
--
-- ปลอดภัยต่อการรันซ้ำ · ชื่อ/พารามิเตอร์ฟังก์ชันเดิม (create or replace)
-- ============================================================================

begin;

create or replace function public.ins_car_gate(p_emp_id text, p_plate text default '',
                                               p_vin text default '', p_brand text default 'toyota')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c_open  interval := interval '5 months';           -- ยื่นต่ออายุได้ล่วงหน้าเท่าไรก่อนหมดอายุ (เดิม 30 วัน)
  v_id    text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_br    text := public.ins_brand(p_brand);
  v_pk    text := public.ins_plate_key(p_plate);
  v_vk    text := public.ins_vin_key(p_vin);
  v_today date := public.ins_today();
  v_pol   record;
  v_req   record;
  v_cars  int;
  v_open  date;
begin
  if length(v_id) < 1 then
    return jsonb_build_object('state', 'first', 'cars', 0, 'needReason', false);
  end if;
  v_cars := public.ins_car_others(v_id, coalesce(p_plate, ''), coalesce(p_vin, ''), null, v_br);

  -- คำขอของ "รถคันเดียวกัน" ที่ยังค้างอยู่ = ห้ามยื่นซ้ำ
  if v_pk <> '' or v_vk <> '' then
    select r.created_at, r.status into v_req
      from public.ins_requests r
     where r.emp_id = v_id and r.brand = v_br and r.kind = 'self'
       and r.status in ('new','contacted','quoted')
       and ((v_pk <> '' and public.ins_plate_key(r.car_plate) = v_pk)
         or (v_vk <> '' and public.ins_vin_key(r.car_vin) = v_vk))
     order by r.created_at desc limit 1;
    if found then
      return jsonb_build_object('state', 'pending', 'cars', v_cars, 'needReason', false,
                                'since', v_req.created_at::date);
    end if;

    -- กรมธรรม์ของรถคันเดียวกัน จาก Excel + ใบที่ปิดการขายในระบบ → ใช้เล่มที่หมดล่าสุด
    select x.plate, x.expire_on into v_pol
      from (
        select a.plate, a.expire_on
          from public.ins_active_policy a
         where a.emp_id = v_id and a.brand = v_br
           and ((v_pk <> '' and public.ins_plate_key(a.plate) = v_pk)
             or (v_vk <> '' and public.ins_vin_key(a.vin) = v_vk))
        union all
        select r.car_plate, coalesce(r.quote_end, r.quote_act_end)
          from public.ins_requests r
         where r.emp_id = v_id and r.brand = v_br and r.kind = 'self' and r.status = 'done'
           and coalesce(r.quote_end, r.quote_act_end) is not null
           and ((v_pk <> '' and public.ins_plate_key(r.car_plate) = v_pk)
             or (v_vk <> '' and public.ins_vin_key(r.car_vin) = v_vk))
      ) x
     order by x.expire_on desc
     limit 1;

    -- เล่มล่าสุดยังไม่หมดอายุ → ต่อได้เมื่อเข้าช่วง 5 เดือนสุดท้าย
    -- (หมดอายุไปแล้ว = ทำใหม่ได้เลย ตกไปกติการถคันแรก/คันที่ 2 ด้านล่าง เหมือนเดิม)
    if v_pol.expire_on is not null and v_pol.expire_on >= v_today then
      v_open := (v_pol.expire_on - c_open)::date;
      return jsonb_build_object(
        'state',      case when v_today >= v_open then 'renew' else 'early' end,
        'cars',       v_cars,
        'needReason', false,
        'plate',      v_pol.plate,
        'expireOn',   v_pol.expire_on,
        'openFrom',   v_open,
        'daysLeft',   v_open - v_today);
    end if;
  end if;

  if v_cars > 0 then
    return jsonb_build_object('state', 'add', 'cars', v_cars, 'needReason', true);
  end if;
  return jsonb_build_object('state', 'first', 'cars', 0, 'needReason', false);
end;
$$;

revoke all on function public.ins_car_gate(text, text, text, text) from public;
grant execute on function public.ins_car_gate(text, text, text, text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยก — อ่านอย่างเดียว)
--
-- A) กติกาใหม่เข้าแล้ว (ต้องได้ true)
--   select position('5 months' in pg_get_functiondef(
--            'public.ins_car_gate(text,text,text,text)'::regprocedure)) > 0 as ห้าเดือน;
--
-- B) ลองกับรถจริง 1 คันจาก Excel — ดูวันที่เริ่มยื่นได้
--   select a.emp_id, a.plate, a.expire_on as หมดอายุ,
--          public.ins_car_gate(a.emp_id, a.plate, a.vin, a.brand) ->> 'state'    as สถานะ,
--          public.ins_car_gate(a.emp_id, a.plate, a.vin, a.brand) ->> 'openFrom' as ยื่นได้ตั้งแต่
--     from public.ins_active_policy a
--    where a.expire_on >= public.ins_today()
--    order by a.expire_on limit 5;
--   → ใบที่หมดภายใน 5 เดือน = renew · ไกลกว่านั้น = early
--
-- ย้อนกลับเป็น 30 วัน: แก้บรรทัด c_open เป็น interval '30 days' แล้วรันไฟล์นี้ซ้ำ
-- ============================================================================
