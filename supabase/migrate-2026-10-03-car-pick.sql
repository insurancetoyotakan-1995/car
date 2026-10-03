-- ============================================================================
-- ขั้นที่ 1 ถามตรง ๆ ว่า "ต่ออายุคันเดิม" หรือ "ทำประกันรถอีกคัน" — 2026-10-03 (ผู้ใช้สั่ง)
--
--   เดิม: ขั้นที่ 1 ยังไม่มีทะเบียน (อยู่ขั้นที่ 3) → คนที่มาต่ออายุรถคันเดียวที่มี
--         ถูกนับเป็น "มีรถที่ใช้สิทธิ์อยู่แล้ว 1 คัน" และถูกบังคับเลือกเหตุผลขอเพิ่มรถ
--   ใหม่: ins_car_gate สถานะ 'add' ส่งรายการรถที่มีอยู่กลับมาด้วย (list)
--         ฟอร์มแสดงทะเบียนให้กด "ต่ออายุคันนี้" (เติมทะเบียนให้ → ตรวจใหม่เป็น renew/early)
--         หรือ "ทำประกันรถอีกคัน" (ค่อยถามเหตุผลขอเพิ่มรถเหมือนเดิม)
--
--   🔒 ผู้ใช้รับทราบแล้ว (2026-10-02): ฟอร์มไม่มีล็อกอิน ใครรู้รหัสพนักงานจะเห็นทะเบียนรถของคนนั้น
--      ส่งแค่ทะเบียน + วันหมดอายุ — ไม่ส่งเลขตัวถัง · สูงสุด 5 คัน
--
--   ins_car_gate = ตัวเดียวกับ migrate-2026-10-01-renew-5m.sql ทุกบรรทัด เพิ่มแค่ 'list' ในสถานะ 'add'
--   ins_car_list นับรถแหล่งเดียวกับ ins_car_others (ใบคำขอ 12 เดือน + Excel ที่ยังไม่หมดอายุ)
--     + ใบที่ปิดการขายในระบบที่ยังไม่หมดอายุ (ให้ตรงกับด่านต่ออายุ)
--
-- ปลอดภัยต่อการรันซ้ำ · ชื่อ/พารามิเตอร์ ins_car_gate เดิม (create or replace)
-- ============================================================================

begin;

-- ---------- รายการรถของพนักงาน (ใช้ภายในเท่านั้น) ----------
create or replace function public.ins_car_list(p_emp text, p_brand text default 'toyota')
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with cars as (
    select r.car_plate as plate, public.ins_plate_key(r.car_plate) as pk, public.ins_vin_key(r.car_vin) as vk,
           r.id::text as fb, coalesce(r.quote_end, r.quote_act_end) as expire_on
      from public.ins_requests r
     where r.emp_id = p_emp
       and r.brand = public.ins_brand(p_brand)
       and r.kind = 'self'
       and r.status <> 'cancelled'
       and (r.created_at > now() - interval '12 months'
            or (r.status = 'done' and coalesce(r.quote_end, r.quote_act_end) >= public.ins_today()))
       and r.covers is distinct from array['act']::text[]
    union all
    select a.plate, public.ins_plate_key(a.plate), public.ins_vin_key(a.vin), 'p' || a.id, a.expire_on
      from public.ins_active_policy a
     where a.emp_id = p_emp
       and a.brand = public.ins_brand(p_brand)
       and a.expire_on >= public.ins_today()
  ), one as (
    -- รถคันเดียวกัน (ทะเบียน/เลขตัวถังตรง) เหลือแถวเดียว · ใช้เล่มที่หมดช้าสุด
    select distinct on (coalesce(nullif(pk, ''), nullif(vk, ''), fb))
           btrim(coalesce(plate, '')) as plate, expire_on
      from cars
     order by coalesce(nullif(pk, ''), nullif(vk, ''), fb), expire_on desc nulls last
  )
  select coalesce(jsonb_agg(jsonb_build_object('plate', plate, 'expireOn', expire_on)
                            order by expire_on nulls last), '[]'::jsonb)
    from (select * from one order by expire_on nulls last limit 5) x;
$$;
revoke all on function public.ins_car_list(text, text) from public, anon, authenticated;

-- ---------- ด่านสิทธิ์ (เหมือน 2026-10-01 + list) ----------
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
    -- list: ให้ผู้กรอกเลือก "ต่ออายุคันนี้" ได้ตั้งแต่ขั้นที่ 1 (ยังไม่กรอกทะเบียน)
    -- กรอกทะเบียนแล้วแต่ยังเป็นคันอื่น ไม่ต้องส่งรายการ — ฟอร์มจะถามเหตุผลอย่างเดียว
    return jsonb_build_object('state', 'add', 'cars', v_cars, 'needReason', true,
                              'list', case when v_pk = '' and v_vk = '' then public.ins_car_list(v_id, v_br)
                                           else '[]'::jsonb end);
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
--   พนักงานที่มีรถ 1 คันในระบบ (ไม่ส่งทะเบียน) → ต้องได้ state = add และ list มีทะเบียน 1 คัน
--   select a.emp_id,
--          public.ins_car_gate(a.emp_id, '', '', a.brand) ->> 'state' as สถานะ,
--          public.ins_car_gate(a.emp_id, '', '', a.brand) -> 'list'   as รายการรถ
--     from public.ins_active_policy a
--    where a.expire_on >= public.ins_today()
--    limit 3;
--
-- ย้อนกลับ: รัน migrate-2026-10-01-renew-5m.sql ซ้ำ (ฟอร์มเห็น list ว่าง = กลับไปถามเหตุผลเหมือนเดิม)
-- ============================================================================
