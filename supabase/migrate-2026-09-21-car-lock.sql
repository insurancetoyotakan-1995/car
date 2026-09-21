-- ============================================================================
-- ล็อกสิทธิ์ต่อประกันของพนักงาน + เมนูขอเพิ่มรถ (2026-09-21)
--
--   กติกา (ผู้ใช้กำหนด)
--     • รถคันเดิมของพนักงาน (ทะเบียนหรือเลขตัวถังตรงกับกรมธรรม์ที่ยังไม่หมดอายุ)
--       → ยื่นใหม่ได้เมื่อเหลืออายุไม่เกิน 1 เดือน (ประมาณเดือนที่ 11 ของรอบ 12 เดือน)
--       ยังไม่ถึงกำหนด = ส่งคำขอไม่ได้ (ด่านอยู่ที่ ins_submit ไม่ใช่แค่หน้าเว็บ)
--     • รถคนละคัน = ปลดล็อกได้ แต่ต้องเลือกเหตุผล
--         own2   = ขอเพิ่มรถคันที่ 2 ชื่อตัวเอง
--         family = รถครอบครัวเชื่อมโยง
--       ไม่เลือก = ส่งไม่ได้ · เหตุผลถูกเก็บลงฐานข้อมูลและแสดงในหน้าเจ้าหน้าที่/ข้อความ LINE
--     • ใบที่มีคำขอของรถคันเดียวกันค้างอยู่ (ยังไม่ปิด/ไม่ยกเลิก) = ส่งซ้ำไม่ได้
--
--   add_reason: first (คันแรก) · renew (ต่ออายุคันเดิม) · own2 · family
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-19-active-policy.sql
-- 🔑 ไม่เขียน ins_submit ใหม่ทั้งตัว — "แทนข้อความ" ในตัวที่อยู่บน prod ตอนนี้
--    (แพตเทิร์นเดียวกับ migrate-2026-09-18-car-reg.sql) · หาจุดไม่เจอ = หยุดทั้งไฟล์ ไม่แก้ครึ่ง ๆ
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ใหม่ ----------
alter table public.ins_requests
  add column if not exists add_reason text;
alter table public.ins_requests drop constraint if exists ins_requests_add_reason_chk;
alter table public.ins_requests add constraint ins_requests_add_reason_chk
  check (add_reason is null or add_reason in ('first','renew','own2','family'));

-- ---------- 2) ด่านสิทธิ์: รถคันนี้ของพนักงานคนนี้ ยื่นได้ไหม ----------
--   คืน jsonb ให้ทั้งฟอร์ม (anon) และ ins_submit ใช้กติกาเดียวกัน
--     state = first  : ยังไม่มีรถที่ใช้สิทธิ์อยู่ → ยื่นได้
--             renew  : รถคันเดิม ถึงกำหนดต่อแล้ว → ยื่นได้
--             early  : รถคันเดิม ยังไม่ถึงกำหนด → ยื่นไม่ได้ (openFrom = วันที่เริ่มยื่นได้)
--             pending: มีคำขอของรถคันนี้ค้างอยู่ → ยื่นไม่ได้
--             add    : รถคนละคัน → ยื่นได้เมื่อเลือกเหตุผล (needReason = true)
create or replace function public.ins_car_gate(p_emp_id text, p_plate text default '', p_vin text default '')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c_open  int := 30;                                   -- ยื่นต่ออายุได้ล่วงหน้ากี่วันก่อนหมดอายุ
  v_id    text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_pk    text := public.ins_plate_key(p_plate);
  v_vk    text := public.ins_vin_key(p_vin);
  v_today date := public.ins_today();
  v_pol   record;
  v_req   record;
  v_cars  int;
begin
  if length(v_id) < 4 then
    return jsonb_build_object('state', 'first', 'cars', 0, 'needReason', false);
  end if;
  v_cars := public.ins_car_others(v_id, coalesce(p_plate, ''), coalesce(p_vin, ''), null);

  -- คำขอของ "รถคันเดียวกัน" ที่ยังค้างอยู่ = ห้ามยื่นซ้ำ
  if v_pk <> '' or v_vk <> '' then
    select r.created_at, r.status into v_req
      from public.ins_requests r
     where r.emp_id = v_id and r.kind = 'self'
       and r.status in ('new','contacted','quoted')
       and ((v_pk <> '' and public.ins_plate_key(r.car_plate) = v_pk)
         or (v_vk <> '' and public.ins_vin_key(r.car_vin) = v_vk))
     order by r.created_at desc limit 1;
    if found then
      return jsonb_build_object('state', 'pending', 'cars', v_cars, 'needReason', false,
                                'since', v_req.created_at::date);
    end if;

    -- กรมธรรม์ของรถคันเดียวกันที่ยังไม่หมดอายุ → ต่อได้เมื่อเหลือไม่เกิน c_open วัน
    select a.plate, a.expire_on into v_pol
      from public.ins_active_policy a
     where a.emp_id = v_id
       and a.expire_on >= v_today
       and ((v_pk <> '' and public.ins_plate_key(a.plate) = v_pk)
         or (v_vk <> '' and public.ins_vin_key(a.vin) = v_vk))
     order by a.expire_on limit 1;
    if found then
      return jsonb_build_object(
        'state',      case when v_today >= v_pol.expire_on - c_open then 'renew' else 'early' end,
        'cars',       v_cars,
        'needReason', false,
        'plate',      v_pol.plate,
        'expireOn',   v_pol.expire_on,
        'openFrom',   v_pol.expire_on - c_open,
        'daysLeft',   (v_pol.expire_on - c_open) - v_today);
    end if;
  end if;

  if v_cars > 0 then
    return jsonb_build_object('state', 'add', 'cars', v_cars, 'needReason', true);
  end if;
  return jsonb_build_object('state', 'first', 'cars', 0, 'needReason', false);
end;
$$;

-- ---------- 3) ให้ ins_submit บังคับกติกา + เก็บเหตุผล ----------
do $f$
declare
  d    text;
  a1   text := '  v_relation  text;';
  a1n  text := '  v_relation  text;' || chr(10) || '  v_add       text;' || chr(10) || '  v_gate      jsonb;';
  a2   text := 'car_province, car_vin';
  a2n  text := 'car_province, car_vin, add_reason';
  a3   text := 'nullif(left(upper(regexp_replace(coalesce(payload->>''carVin'', ''''), ''[^0-9A-Za-z]'', '''', ''g'')), 25), '''')';
  a3n  text := a3 || ',' || chr(10) || '    v_add';
  a4   text := '  insert into public.ins_requests';
  a4n  text := $g$  -- ---- ด่านสิทธิ์ต่อประกัน (migrate-2026-09-21-car-lock.sql) ----
  v_add := nullif(btrim(coalesce(payload->>'addReason', '')), '');
  if v_add is not null and v_add not in ('own2','family') then v_add := null; end if;
  if v_kind = 'self' and v_emp_id <> '' then
    v_gate := public.ins_car_gate(v_emp_id, payload->>'carPlate', payload->>'carVin');
    if v_gate->>'state' = 'early' then
      raise exception 'รถทะเบียน % ยังต่ออายุไม่ได้ — ยื่นได้ตั้งแต่ % (กรมธรรม์เดิมหมดอายุ %)',
        coalesce(v_gate->>'plate', '-'), v_gate->>'openFrom', v_gate->>'expireOn' using errcode = 'P0001';
    elsif v_gate->>'state' = 'pending' then
      raise exception 'มีคำขอของรถคันนี้อยู่ในระบบแล้ว (ยื่นเมื่อ %) — เจ้าหน้าที่กำลังดำเนินการ',
        v_gate->>'since' using errcode = 'P0001';
    elsif v_gate->>'state' = 'add' and v_add is null then
      raise exception 'พนักงานมีรถที่ใช้สิทธิ์อยู่แล้ว — ต้องเลือกเหตุผลขอเพิ่มรถก่อน (รถคันที่ 2 ชื่อตัวเอง หรือ รถครอบครัวเชื่อมโยง)'
        using errcode = 'P0001';
    end if;
    v_add := case when v_gate->>'state' = 'add' then v_add else v_gate->>'state' end;
  else
    v_add := null;                                     -- แบบแนะนำลูกค้า ไม่เกี่ยวกับสิทธิ์พนักงาน
  end if;

  insert into public.ins_requests$g$;
  n    int;
  v_a  text;
begin
  d := pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure);
  if position('ins_car_gate' in d) > 0 then
    raise notice 'ins_submit มีด่านสิทธิ์อยู่แล้ว — ข้าม';
  else
    if position('car_province, car_vin' in d) = 0 then
      raise exception 'ins_submit ยังไม่ได้รัน migrate-2026-09-18-car-reg.sql — หยุด';
    end if;
    foreach v_a in array array[a1, a2, a3, a4] loop
      n := (length(d) - length(replace(d, v_a, ''))) / length(v_a);
      if n <> 1 then raise exception 'ins_submit: หา "%" เจอ % จุด (ต้อง 1)', left(v_a, 40), n; end if;
    end loop;
    d := replace(d, a1, a1n);
    d := replace(d, a2, a2n);
    d := replace(d, a3, a3n);
    d := replace(d, a4, a4n);
    execute d;                                          -- create or replace → สิทธิ์เดิมยังอยู่ครบ
  end if;
end $f$;

-- ---------- 4) วิวสำหรับหน้าเจ้าหน้าที่ (เพิ่ม add_reason) ----------
create or replace view public.ins_requests_view
with (security_invoker = true) as
  select id, no, kind,
         emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
         insured_name, addr, moo, road, tambon, amphoe, province,
         phone_home, phone_mobile, relation, relation_note,
         car_brand, car_model, car_plate, car_year, covers,
         doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note,
         note, status, status_note, created_at, updated_at,
         assigned_to, assigned_at,
         id_card, zipcode, occupation, workplace, income,
         consent_at, consent_version, birth_date,
         insured_title,
         quote_insurer, quote_type,
         quote_net, quote_gross, quote_disc,
         quote_act_net, quote_act_gross, quote_act_disc,
         quote_total, quote_note, quote_at, quote_by,
         car_province, car_vin,
         quote_start, quote_act_start, quote_end, quote_act_end,
         add_reason
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;

-- ---------- 5) ข้อความ LINE บอกเหตุผลขอเพิ่มรถ ----------
create or replace function public.ins_line_text(p_req public.ins_requests, p_head text, p_with_agent boolean)
returns text
language plpgsql stable
security definer
set search_path = public
as $$
declare
  v_agent text;
  v_refer boolean := p_req.kind = 'refer';
  v_cars  integer := 0;
  v_why   text := case p_req.add_reason
                    when 'own2'   then 'ขอเพิ่มรถคันที่ 2 ชื่อตัวเอง'
                    when 'family' then 'รถครอบครัวเชื่อมโยง'
                    when 'renew'  then 'ต่ออายุรถคันเดิม'
                    else null end;
begin
  if p_with_agent then
    select coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id) into v_agent
      from public.ins_staff s left join public.employees e on e.emp_id = s.emp_id
     where s.emp_id = p_req.assigned_to;
  end if;
  if not v_refer and coalesce(p_req.emp_id, '') <> '' then
    v_cars := public.ins_car_others(p_req.emp_id, p_req.car_plate, p_req.car_vin, p_req.id);
  end if;
  return p_head
    || E'\nเลขที่: ' || p_req.no
    || E'\nแบบคำขอ: ' || case when v_refer then 'แนะนำลูกค้าทั่วไป' else 'พนักงานทำประกันเอง' end
    || E'\n' || case when v_refer then 'ลูกค้า: ' else 'ผู้ทำประกัน: ' end || regexp_replace(p_req.insured_name, '\s+', ' ', 'g')
    || E'\nโทร: ' || coalesce(nullif(p_req.phone_mobile, ''), '-')
    || E'\n' || case when v_refer then 'ผู้แนะนำ: ' else 'พนักงาน: ' end
    || regexp_replace(p_req.emp_name, '\s+', ' ', 'g')
    || case when coalesce(p_req.emp_dept, '') <> '' then ' (' || p_req.emp_dept || ')' else '' end
    || case when p_req.emp_verified then '' else ' · รหัสยังไม่ยืนยัน' end
    || case when v_why is not null then E'\nเหตุผล: ' || v_why else '' end
    || case when v_cars > 0
            then E'\n⚠️ รถคันที่ ' || (v_cars + 1) || ' ของพนักงาน — สิทธิ์ส่วนลด 10% เงินสด/โอนเท่านั้น'
            else '' end
    || case when p_with_agent then E'\nผู้ดูแล: ' || coalesce(v_agent, 'ยังไม่มี') else '' end
    || E'\n\nเปิดดู: https://insurancetoyotakan-1995.github.io/car/staff.html?no=' || p_req.no;
end;
$$;

-- ---------- 6) สิทธิ์ ----------
revoke all on function public.ins_car_gate(text, text, text)                    from public;
grant execute on function public.ins_car_gate(text, text, text)                 to anon, authenticated;
revoke all on function public.ins_line_text(public.ins_requests, text, boolean)  from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select position('ins_car_gate' in pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure)) > 0 as submit_ok,
--          (select count(*) from information_schema.columns
--            where table_name='ins_requests_view' and column_name = 'add_reason') as view_col,
--          public.ins_car_gate('00000000')->>'state' as gate_demo;
--   -- ต้องได้ submit_ok = true · view_col = 1 · gate_demo = first
-- ============================================================================
