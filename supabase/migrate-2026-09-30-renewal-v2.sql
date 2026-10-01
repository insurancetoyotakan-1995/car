-- ============================================================================
-- ต่ออายุกรมธรรม์ v2 + วันหมดอายุกรมธรรม์เดิม — 2026-09-30
--
-- ปัญหาเดิม (migrate-2026-09-22-renewal.sql)
--   1) แถบ "ต่ออายุกรมธรรม์" อ่านจาก ins_active_policy (Excel) ตารางเดียว
--      → กรมธรรม์ที่ปิดการขายผ่านระบบนี้ ไม่ขึ้นรายการต่ออายุปีหน้าเลย
--        อีก ~1 ปี ข้อมูล Excel หมดอายุหมด แถบนี้จะว่างทั้งที่ลูกค้ายังอยู่
--   2) 🐞 ต่ออายุเสร็จ (ใบต่ออายุปิดการขาย) รถคันนั้นเด้งกลับมา "เลยกำหนด" อีกรอบ
--      เพราะวันหมดอายุใน Excel ยังเป็นวันเดิม และตัวเช็ค "มีใบค้างไหม" ไม่นับใบที่ปิดแล้ว
--      (ยังไม่เกิดจริงเพราะรอบต่ออายุแรกคือ ต.ค. 69 — แก้ก่อนถึง)
--
-- วิธีใหม่: รถ 1 คัน = 1 แถว ใช้ "วันหมดอายุล่าสุดที่ระบบรู้" จาก 2 แหล่ง
--   A) Excel ฝ่ายประกัน (ins_active_policy)
--   B) ใบที่ปิดการขายในระบบ — วันสิ้นสุดความคุ้มครองที่เจ้าหน้าที่กรอกตอนเสนอราคา
--      (ภาคสมัครใจก่อน ไม่มีค่อยใช้ พ.ร.บ.)
--   → ต่ออายุแล้วรถเลื่อนไปปีถัดไปเอง · ขายผ่านระบบแล้วปีหน้าขึ้นรายการเอง
--   → ใบ "แนะนำลูกค้า" ขึ้นด้วย (ลูกค้าภายนอกก็ต้องต่ออายุ) พร้อมชื่อและเบอร์ของลูกค้าเอง
--
-- ของใหม่อีกอย่าง: ins_requests.old_policy_end = วันหมดอายุกรมธรรม์เดิมที่ผู้กรอกบอกมา (ไม่บังคับ)
--   ใบต่ออายุที่เจ้าหน้าที่กดสร้าง ระบบเติมช่องนี้ให้เองจากวันหมดอายุของเล่มเดิม
--
-- ปลอดภัยต่อการรันซ้ำ · ทั้งไฟล์เป็น transaction เดียว หาจุดแก้ไม่เจอ = ยกเลิกทั้งหมด
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์วันหมดอายุกรมธรรม์เดิม ----------
alter table public.ins_requests add column if not exists old_policy_end date;

-- ---------- 2) view: ต่อคอลัมน์ใหม่ไว้ท้ายสุด ----------
--   create or replace view เพิ่มคอลัมน์ได้เฉพาะ "ท้ายสุด" — อ่านนิยามปัจจุบันแล้วต่อท้าย
--   ไม่เขียนรายชื่อคอลัมน์ใหม่เอง เพราะ view ถูกต่อเติมมาหลายไฟล์ พิมพ์เองเสี่ยงหล่นคอลัมน์
do $v$
declare
  d text := pg_get_viewdef('public.ins_requests_view'::regclass, true);
  n int;
begin
  if position('old_policy_end' in d) > 0 then
    raise notice 'ins_requests_view: มี old_policy_end แล้ว — ข้าม';
    return;
  end if;
  n := (select count(*) from regexp_matches(d, 'FROM\s+(public\.)?ins_requests', 'g'));
  if n <> 1 then
    raise exception 'ins_requests_view: หา FROM ins_requests ไม่เจอหรือเจอ % ที่ (ต้องเจอ 1 ที่)', n;
  end if;
  d := regexp_replace(d, '(FROM\s+(public\.)?ins_requests)', ', old_policy_end \1');
  execute 'create or replace view public.ins_requests_view with (security_invoker = true) as '
          || rtrim(d, '; ' || chr(10));
end $v$;

-- ---------- 3) ins_submit: เก็บวันหมดอายุที่ผู้กรอกส่งมา ----------
--   เสียบคำสั่ง update ไว้ก่อน return (หลังสร้างใบแล้ว มี v_id)
--   🔑 ผิดรูปแบบ/วันไม่มีจริง (31/02) = ข้ามเงียบ ๆ — ช่องไม่บังคับต้องไม่ทำให้ทั้งใบส่งไม่ผ่าน
--   🔑 ใน regexp_replace ห้ามมี backslash ในข้อความที่เสียบ (จะกลายเป็น backreference) จึงใช้ [0-9] แทน \d
do $f$
declare
  d   text := pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure);
  ins text := '-- วันหมดอายุกรมธรรม์เดิม (ไม่บังคับ) — migrate-2026-09-30-renewal-v2' || chr(10)
    || '  begin' || chr(10)
    || '    if coalesce(payload->>''oldPolicyEnd'', '''') ~ ''^[0-9]{4}-[0-9]{2}-[0-9]{2}$'' then' || chr(10)
    || '      update public.ins_requests set old_policy_end = (payload->>''oldPolicyEnd'')::date where id = v_id;' || chr(10)
    || '    end if;' || chr(10)
    || '  exception when others then null;' || chr(10)
    || '  end;' || chr(10) || chr(10) || '  ';
  n   int;
begin
  if position('oldPolicyEnd' in d) > 0 then
    raise notice 'ins_submit: เก็บวันหมดอายุกรมธรรม์เดิมอยู่แล้ว — ข้าม';
    return;
  end if;
  n := (select count(*) from regexp_matches(d, 'return\s+jsonb_build_object\(\s*''assignee''', 'g'));
  if n <> 1 then
    raise exception 'ins_submit: หาจุด return ไม่เจอหรือเจอ % ที่ (ต้องเจอ 1 ที่)', n;
  end if;
  execute regexp_replace(d, '(return\s+jsonb_build_object\(\s*''assignee'')', ins || '\1');
end $f$;

-- ---------- 4) รายการต่ออายุ v2 ----------
--   เปลี่ยนคอลัมน์ที่คืน → ต้อง drop ก่อน · คอลัมน์เดิมอยู่ครบลำดับเดิม ต่อท้าย 3 ตัวใหม่
--     insured_name = ชื่อผู้เอาประกันจากใบ (อาจเป็นครอบครัวพนักงาน / ลูกค้าที่แนะนำ)
--     kind         = self / refer
--     src_no       = เลขที่ใบที่ปิดการขาย (ว่าง = มาจาก Excel)
--   🔑 ทุกคอลัมน์ในคำสั่งต้องมีชื่อตาราง/alias นำ — ชื่อคอลัมน์ที่คืนเป็นตัวแปรใน plpgsql ด้วย
--      (brand, emp_id, kind …) อ้างลอย ๆ จะชนแล้ว error "ambiguous"
drop function if exists public.ins_renewals(int);
create or replace function public.ins_renewals(p_days int default 90)
returns table (
  brand text, emp_id text, emp_name text, plate text, vin text,
  expire_on date, days_left int, phone_mobile text,
  agent_emp_id text, agent_name text, open_no text, open_status text,
  insured_name text, kind text, src_no text
)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  return query
  with src as (
    -- A) กรมธรรม์ที่ฝ่ายประกันนำเข้าจาก Excel
    select a.brand as s_brand, a.emp_id as s_emp, a.plate as s_plate, a.vin as s_vin,
           a.expire_on as s_end, null::text as s_no, null::text as s_insured,
           null::text as s_phone, 'self'::text as s_kind, null::text as s_agent
      from public.ins_active_policy a
    union all
    -- B) ใบที่ปิดการขายในระบบนี้
    select r.brand, r.emp_id, r.car_plate, r.car_vin,
           coalesce(r.quote_end, r.quote_act_end), r.no,
           nullif(btrim(r.insured_name), ''),   -- ไม่ใส่คำนำหน้า: หน้าเว็บเทียบกับชื่อพนักงาน (ทำเนียบไม่มีคำนำหน้า)
           nullif(btrim(r.phone_mobile), ''), r.kind, r.assigned_to
      from public.ins_requests r
     where r.status = 'done' and coalesce(r.quote_end, r.quote_act_end) is not null
  ),
  keyed as (
    -- รถคันเดียวกัน = ทะเบียนเดียวกัน (ไม่มีทะเบียนใช้เลขตัวรถ · ไม่มีทั้งคู่ = แยกแถวไว้ ไม่เดา)
    select s.*,
           coalesce(nullif(public.ins_plate_key(s.s_plate), ''),
                    nullif(public.ins_vin_key(s.s_vin), ''),
                    'x:' || coalesce(s.s_no, s.s_emp || '|' || s.s_end::text)) as s_key
      from src s
  ),
  latest as (
    -- วันหมดอายุล่าสุดของรถแต่ละคัน · วันเท่ากันให้ใบในระบบชนะ (ข้อมูลครบกว่า Excel)
    select distinct on (k.s_brand, k.s_key) k.*
      from keyed k
     order by k.s_brand, k.s_key, k.s_end desc, (k.s_no is not null) desc
  ),
  pol as (
    select l.* from latest l
     where l.s_end <= public.ins_today() + greatest(coalesce(p_days, 90), 0)
  ),
  own as (
    -- ผู้ดูแล: คนที่ขายใบนั้น → ผู้ดูแลใบล่าสุดของพนักงาน → mapping จาก Excel
    select p.s_brand as o_brand, p.s_key as o_key,
           coalesce(
             p.s_agent,
             (select r.assigned_to from public.ins_requests r
               where r.emp_id = p.s_emp and r.brand = p.s_brand and r.kind = 'self'
                 and r.status <> 'cancelled' and r.assigned_to is not null
               order by r.created_at desc limit 1),
             (select o.agent_emp_id from public.ins_emp_owner o
               where o.emp_id = p.s_emp and o.brand = p.s_brand)
           ) as o_agent
      from pol p
  )
  select p.s_brand, p.s_emp,
         coalesce(e.name, p.s_emp),
         p.s_plate, p.s_vin, p.s_end,
         (p.s_end - public.ins_today())::int,
         coalesce(p.s_phone, ad.phone_mobile, ''),
         w.o_agent,
         coalesce(ae.name, nullif(split_part(st.note, ' · ', 1), ''), w.o_agent),
         q.no, q.status,
         p.s_insured, p.s_kind, p.s_no
    from pol p
    left join own w                   on w.o_brand = p.s_brand and w.o_key = p.s_key
    left join public.employees e      on e.emp_id = p.s_emp and e.brand = p.s_brand
    left join public.ins_emp_addr ad  on ad.emp_id = p.s_emp and ad.brand = p.s_brand
    left join public.ins_staff st     on st.emp_id = w.o_agent
    left join public.employees ae     on ae.emp_id = w.o_agent and ae.brand = coalesce(st.brand, 'toyota')
    left join lateral (
      -- มีใบของรถคันนี้ที่ยังทำอยู่ไหม (ไม่สนว่าใครยื่น/แบบไหน — รถ 1 คันมีใบค้างได้ใบเดียว)
      select r.no, r.status
        from public.ins_requests r
       where r.brand = p.s_brand
         and r.status not in ('done','cancelled')
         and ((public.ins_plate_key(p.s_plate) <> ''
               and public.ins_plate_key(r.car_plate) = public.ins_plate_key(p.s_plate))
           or (public.ins_vin_key(p.s_vin) <> ''
               and public.ins_vin_key(r.car_vin) = public.ins_vin_key(p.s_vin)))
       order by r.created_at desc limit 1
    ) q on true
   where public.is_ins_admin() or w.o_agent is null or w.o_agent = public.ins_my_emp()
   order by p.s_end, p.s_emp;
end;
$$;
revoke all on function public.ins_renewals(int) from public, anon;
grant execute on function public.ins_renewals(int) to authenticated;

-- ---------- 5) สร้างใบต่ออายุ v2 ----------
--   แหล่งข้อมูลเลือกตามวันหมดอายุล่าสุดของรถคันนั้น (กติกาเดียวกับรายการด้านบน)
--     ใบที่ปิดการขายในระบบ → คัดลอกทั้งใบ: ผู้เอาประกัน บัตร วันเกิด ที่อยู่ อาชีพ รถ ความคุ้มครอง
--                              (ต่ออายุคนเดิมรถเดิม ไม่ต้องถามลูกค้าซ้ำ) · ผู้ดูแล = คนที่ขายใบเดิม
--     Excel                  → แบบเดิม: ชื่อจากทำเนียบ ที่อยู่/เบอร์จาก ins_emp_addr
--   ใบใหม่ได้ old_policy_end = วันหมดอายุของเล่มเดิม ให้เจ้าหน้าที่ตั้งวันเริ่มคุ้มครองได้ทันที
--   🔑 กันสร้างซ้ำ: รถคันนี้มีใบที่ยังไม่ปิด/ไม่ยกเลิก = ไม่สร้างใหม่
create or replace function public.ins_renew_start(p_brand text, p_emp text, p_plate text, p_vin text default '')
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_br    text := public.ins_brand(p_brand);
  v_id    text := regexp_replace(coalesce(p_emp, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_pk    text := public.ins_plate_key(p_plate);
  v_vk    text := public.ins_vin_key(p_vin);
  v_req   public.ins_requests;
  v_pol   record;
  v_emp   record;
  v_ad    record;
  v_end   date;
  v_dup   text;
  v_agent text;
  v_ym    text;
  v_n     integer;
  v_no    text;
  v_token text;
  v_new   uuid;
  v_src   text;
  v_has_addr boolean := false;
  /* 🔑 v_ad ถูกเติมเฉพาะทาง Excel — ห้ามอ้าง v_ad.* ในนิพจน์ที่ทางใบในระบบก็รันด้วย
        (plpgsql ดึงค่าตัวแปรทั้งนิพจน์ก่อนประเมิน CASE → "record v_ad is not assigned yet")
        จึงคิด v_has_addr แยกในแต่ละทางแทน */
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  if v_pk = '' and v_vk = '' then
    raise exception 'ต้องระบุทะเบียนรถหรือเลขตัวรถ' using errcode = 'P0001';
  end if;

  -- ใบที่ปิดการขายล่าสุดของรถคันนี้
  select r.* into v_req
    from public.ins_requests r
   where r.brand = v_br and r.status = 'done'
     and coalesce(r.quote_end, r.quote_act_end) is not null
     and ((v_pk <> '' and public.ins_plate_key(r.car_plate) = v_pk)
       or (v_vk <> '' and public.ins_vin_key(r.car_vin) = v_vk))
   order by coalesce(r.quote_end, r.quote_act_end) desc, r.created_at desc
   limit 1;

  -- กรมธรรม์จาก Excel ของรถคันนี้ (เล่มที่หมดล่าสุด)
  select a.plate, a.vin, a.expire_on into v_pol
    from public.ins_active_policy a
   where a.brand = v_br and a.emp_id = v_id
     and ((v_pk <> '' and public.ins_plate_key(a.plate) = v_pk)
       or (v_vk <> '' and public.ins_vin_key(a.vin) = v_vk))
   order by a.expire_on desc limit 1;

  if v_req.id is not null
     and (v_pol.expire_on is null or coalesce(v_req.quote_end, v_req.quote_act_end) >= v_pol.expire_on) then
    v_src := 'request';
    v_end := coalesce(v_req.quote_end, v_req.quote_act_end);
  elsif v_pol.expire_on is not null then
    v_src := 'policy';
    v_end := v_pol.expire_on;
  else
    raise exception 'ไม่พบกรมธรรม์ของรถคันนี้ในระบบ' using errcode = 'P0001';
  end if;

  select r.no into v_dup
    from public.ins_requests r
   where r.brand = v_br
     and r.status not in ('done','cancelled')
     and ((v_pk <> '' and public.ins_plate_key(r.car_plate) = v_pk)
       or (v_vk <> '' and public.ins_vin_key(r.car_vin) = v_vk))
   limit 1;
  if v_dup is not null then
    raise exception 'มีใบของรถคันนี้อยู่ในระบบแล้ว (%) — เปิดใบเดิมแทนการสร้างใหม่', v_dup
      using errcode = 'P0001';
  end if;

  if v_src = 'request' then
    -- ผู้ดูแล: คนที่ขายใบเดิม ถ้ายังรับงานอยู่ (บริษัทเดียวกัน) ไม่งั้นใช้กติกาแจกงานปกติ
    select s.emp_id into v_agent from public.ins_staff s
     where s.emp_id = v_req.assigned_to and s.active and s.role = 'agent'
       and s.takes_new and s.brand = v_br;
    if v_agent is null then
      v_agent := public.ins_pick_assignee(v_req.emp_id, v_req.kind, v_br);
    end if;
    v_has_addr := coalesce(v_req.addr, '') <> '';
  else
    select e.name, e.dept into v_emp from public.employees e
     where e.emp_id = v_id and e.brand = v_br and e.active is true;
    if not found then
      raise exception 'ไม่พบรหัสพนักงานนี้ในทำเนียบ' using errcode = 'P0001';
    end if;
    select a.addr, a.moo, a.road, a.tambon, a.amphoe, a.province, a.zipcode, a.phone_mobile
      into v_ad
      from public.ins_emp_addr a
     where a.emp_id = v_id and a.brand = v_br;
    v_has_addr := found and coalesce(v_ad.addr, '') <> '';
    v_agent := public.ins_pick_assignee(v_id, 'self', v_br);
  end if;

  v_ym := to_char(now() at time zone 'Asia/Bangkok', 'YYMM');
  insert into public.ins_seq (ym, n)
       values (case when v_br = 'hino' then 'H' || v_ym else v_ym end, 1)
    on conflict (ym) do update set n = public.ins_seq.n + 1
    returning n into v_n;
  v_no := case when v_br = 'hino' then 'HIN-' else 'INS-' end
          || v_ym || '-' || lpad(v_n::text, greatest(3, length(v_n::text)), '0');
  v_token := encode(gen_random_bytes(16), 'hex');

  if v_src = 'request' then
    insert into public.ins_requests (
      no, brand, kind, emp_id, emp_name, emp_dept, emp_branch, emp_verified,
      insured_title, insured_name, id_card, birth_date,
      addr, moo, road, tambon, amphoe, province, zipcode, phone_mobile, phone_home,
      occupation, workplace, income, relation, relation_note,
      car_brand, car_model, car_year, car_plate, car_province, car_vin, covers,
      note, add_reason, old_policy_end,
      upload_token, assigned_to, assigned_at, status
    ) values (
      v_no, v_br, v_req.kind, v_req.emp_id, v_req.emp_name, v_req.emp_dept, v_req.emp_branch, v_req.emp_verified,
      v_req.insured_title, v_req.insured_name, v_req.id_card, v_req.birth_date,
      v_req.addr, v_req.moo, v_req.road, v_req.tambon, v_req.amphoe, v_req.province,
      v_req.zipcode, v_req.phone_mobile, v_req.phone_home,
      v_req.occupation, v_req.workplace, v_req.income, v_req.relation, v_req.relation_note,
      v_req.car_brand, v_req.car_model, v_req.car_year, v_req.car_plate, v_req.car_province,
      v_req.car_vin, v_req.covers,
      'ต่ออายุจากใบ ' || v_req.no || ' — กรมธรรม์เดิมหมดอายุ ' || to_char(v_end, 'DD/MM/YYYY'),
      case when v_req.kind = 'self' then 'renew' end, v_end,
      v_token, v_agent, case when v_agent is not null then now() else null end, 'new'
    ) returning id into v_new;
  else
    insert into public.ins_requests (
      no, brand, kind, emp_id, emp_name, emp_dept, emp_verified,
      insured_name, addr, moo, road, tambon, amphoe, province, zipcode, phone_mobile,
      relation, car_plate, car_vin, covers, note, add_reason, old_policy_end,
      upload_token, assigned_to, assigned_at, status
    ) values (
      v_no, v_br, 'self', v_id, v_emp.name, coalesce(v_emp.dept, ''), true,
      v_emp.name,
      coalesce(v_ad.addr, ''), coalesce(v_ad.moo, ''), coalesce(v_ad.road, ''),
      coalesce(v_ad.tambon, ''), coalesce(v_ad.amphoe, ''), coalesce(v_ad.province, ''),
      coalesce(v_ad.zipcode, ''), coalesce(v_ad.phone_mobile, ''),
      'self', coalesce(v_pol.plate, ''), coalesce(v_pol.vin, ''), '{}',
      'สร้างจากรายการต่ออายุ — กรมธรรม์เดิมหมดอายุ ' || to_char(v_end, 'DD/MM/YYYY'),
      'renew', v_end, v_token, v_agent,
      case when v_agent is not null then now() else null end, 'new'
    ) returning id into v_new;
  end if;

  return jsonb_build_object('ok', true, 'id', v_new, 'no', v_no, 'from', v_src,
                            'hasAddr', v_has_addr, 'assignee', v_agent);
end;
$$;
revoke all on function public.ins_renew_start(text, text, text, text) from public, anon;
grant execute on function public.ins_renew_start(text, text, text, text) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยก — อ่านอย่างเดียว)
--
-- A) ของใหม่เข้าครบไหม (ต้องได้ true ทุกช่อง)
--   select (select count(*) = 1 from information_schema.columns
--            where table_name = 'ins_requests' and column_name = 'old_policy_end')        as คอลัมน์ใหม่,
--          (select count(*) = 1 from information_schema.columns
--            where table_name = 'ins_requests_view' and column_name = 'old_policy_end')   as view,
--          position('oldPolicyEnd' in
--            pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure)) > 0            as submit_เก็บวันที่;
--
-- B) รายการต่ออายุจะมาจากแหล่งไหนบ้าง (ไม่ผ่านฟังก์ชัน จึงรันใน Editor ได้)
--   select 'Excel' as แหล่ง, count(*) from public.ins_active_policy
--   union all
--   select 'ใบที่ปิดการขาย (มีวันสิ้นสุด)', count(*) from public.ins_requests
--    where status = 'done' and coalesce(quote_end, quote_act_end) is not null
--   union all
--   select '⚠ ใบที่ปิดการขายแต่ไม่มีวันสิ้นสุด (จะไม่ขึ้นรายการต่ออายุ)', count(*) from public.ins_requests
--    where status = 'done' and coalesce(quote_end, quote_act_end) is null;
-- ============================================================================
