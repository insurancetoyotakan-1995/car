-- ⛔⛔ ห้ามรันไฟล์นี้แล้ว — ถูกแทนด้วย migrate-2026-09-15-title.sql (รันไปแล้วบน prod)
--    ถ้ารันซ้ำ ins_submit จะย้อนกลับเป็นรุ่นเก่า แล้วคำนำหน้า/ช่องที่เพิ่มทีหลังจะไม่ถูกบันทึกเงียบ ๆ
--    เก็บไว้เป็นประวัติเท่านั้น

-- =====================================================================
--  migrate 2026-09-15 (3) : วันเดือนปีเกิดผู้ทำประกัน
--  ✅ รวมของวันนี้ทั้งหมดแล้ว (5 ช่องข้อมูลผู้ทำประกัน + ความยินยอม PDPA + วันเกิด)
--     รันไฟล์นี้ไฟล์เดียวพอ · เคยรันไฟล์ก่อนหน้าไปแล้วก็รันไฟล์นี้ได้ ไม่เสียหาย
--  ⚠️ ลำดับ: push หน้าเว็บก่อน แล้วค่อยรันไฟล์นี้
--  วิธีใช้: SQL Editor → วางทั้งไฟล์ → Run
-- =====================================================================

alter table public.ins_requests add column if not exists id_card    text   not null default '';
alter table public.ins_requests add column if not exists zipcode    text   not null default '';
alter table public.ins_requests add column if not exists occupation text   not null default '';
alter table public.ins_requests add column if not exists workplace  text   not null default '';
alter table public.ins_requests add column if not exists income     bigint;
alter table public.ins_requests add column if not exists consent_at      timestamptz;
alter table public.ins_requests add column if not exists consent_version text not null default '';
alter table public.ins_requests add column if not exists birth_date      date;

create or replace function public.ins_submit(payload jsonb)
returns jsonb
language plpgsql
security definer
-- ต้องมี extensions ใน search_path ด้วย เพราะเรียก gen_random_bytes (pgcrypto)
set search_path = public, extensions
as $$
declare
  v_ip        text := coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', '');
  v_kind      text;
  v_emp_id    text;
  v_typed     text;
  v_emp       record;
  v_name      text;
  v_dept      text;
  v_verified  boolean := false;
  v_typedkeep text := null;
  v_insured   text;
  v_mobile    text;
  v_covers    text[];
  v_relation  text;
  v_ym        text;
  v_n         integer;
  v_no        text;
  v_token     text;
  v_id        uuid;
  v_recent    integer;
  v_assignee  text;
  v_contact   jsonb;
  v_idcard    text;
  v_zip       text;
  v_occ       text;
  v_work      text;
  v_income    bigint;
  v_sum       integer := 0;
  v_birth     date;
  c_title     text := '^\s*(ว่าที่\s*ร\.?ต\.?(อ|ท|ญ)?\.?|ว่าที่\s*ร\.?อ\.?|นางสาว|น\.ส\.|นาง|นาย|ดร\.|ผศ\.|รศ\.|ศ\.|คุณ)\s*';
begin
  select count(*) into v_recent from public.ins_submit_log
   where ip = v_ip and created_at > now() - interval '10 minutes';
  if v_recent >= 40 then
    raise exception 'ยื่นคำขอถี่เกินไป กรุณารอสักครู่แล้วลองใหม่' using errcode = 'P0001';
  end if;

  if coalesce(payload->>'hp', '') <> '' then
    raise exception 'ไม่สามารถรับคำขอนี้ได้' using errcode = 'P0001';
  end if;

  v_kind := coalesce(payload->>'kind', 'self');
  if v_kind not in ('self','refer') then v_kind := 'self'; end if;

  v_emp_id := regexp_replace(coalesce(payload->>'empId', ''), '[^0-9A-Za-z_-]', '', 'g');
  v_typed  := btrim(regexp_replace(coalesce(payload->>'empName', ''), c_title, ''));
  if v_emp_id = '' then
    raise exception 'กรุณากรอกรหัสพนักงานผู้แนะนำ' using errcode = 'P0001';
  end if;
  select e.name, e.dept into v_emp from public.employees e
   where e.emp_id = v_emp_id and e.active is true;
  if found then
    v_verified := true;
    v_name := v_emp.name;
    v_dept := coalesce(nullif(v_emp.dept, ''), left(btrim(coalesce(payload->>'empDept', '')), 60));
    if v_typed <> '' and v_typed <> v_emp.name then v_typedkeep := v_typed; end if;
  else
    if v_typed = '' then
      raise exception 'กรุณากรอกชื่อ-นามสกุลพนักงาน' using errcode = 'P0001';
    end if;
    v_name := v_typed;
    v_dept := left(btrim(coalesce(payload->>'empDept', '')), 60);
  end if;

  v_insured := btrim(regexp_replace(coalesce(payload->>'insuredName', ''), c_title, ''));
  if v_insured = '' then
    raise exception 'กรุณากรอกชื่อผู้ทำประกันภัย' using errcode = 'P0001';
  end if;
  v_mobile := regexp_replace(coalesce(payload->>'phoneMobile', ''), '[^0-9+ -]', '', 'g');
  if length(regexp_replace(v_mobile, '[^0-9]', '', 'g')) < 9 then
    raise exception 'กรุณากรอกเบอร์โทรศัพท์มือถือให้ครบ' using errcode = 'P0001';
  end if;

  if btrim(coalesce(payload->>'addr', '')) = '' then
    raise exception 'กรุณากรอกบ้านเลขที่' using errcode = 'P0001';
  end if;
  if btrim(coalesce(payload->>'tambon', '')) = '' then
    raise exception 'กรุณากรอกตำบล / แขวง' using errcode = 'P0001';
  end if;
  if btrim(coalesce(payload->>'amphoe', '')) = '' then
    raise exception 'กรุณากรอกอำเภอ / เขต' using errcode = 'P0001';
  end if;
  if btrim(coalesce(payload->>'province', '')) = '' then
    raise exception 'กรุณากรอกจังหวัด' using errcode = 'P0001';
  end if;

  -- เลขบัตรประชาชน 13 หลัก + ตรวจหลักสุดท้าย (checksum ของกรมการปกครอง)
  v_idcard := regexp_replace(coalesce(payload->>'idCard', ''), '[^0-9]', '', 'g');
  if length(v_idcard) <> 13 then
    raise exception 'กรุณากรอกเลขบัตรประชาชนให้ครบ 13 หลัก' using errcode = 'P0001';
  end if;
  for i in 1..12 loop
    v_sum := v_sum + substr(v_idcard, i, 1)::int * (14 - i);
  end loop;
  if (11 - v_sum % 11) % 10 <> substr(v_idcard, 13, 1)::int then
    raise exception 'เลขบัตรประชาชนไม่ถูกต้อง กรุณาตรวจสอบอีกครั้ง' using errcode = 'P0001';
  end if;

  -- วันเกิด: หน้าเว็บส่งเป็น yyyy-mm-dd (ค.ศ.) · อายุ 15–100 ปี
  begin
    v_birth := nullif(btrim(coalesce(payload->>'birthDate', '')), '')::date;
  exception when others then
    v_birth := null;
  end;
  if v_birth is null then
    raise exception 'กรุณากรอกวันเดือนปีเกิด' using errcode = 'P0001';
  end if;
  if v_birth > (now() at time zone 'Asia/Bangkok')::date - interval '15 years'
     or v_birth < (now() at time zone 'Asia/Bangkok')::date - interval '101 years' then
    raise exception 'วันเดือนปีเกิดไม่ถูกต้อง กรุณาตรวจปี พ.ศ. อีกครั้ง' using errcode = 'P0001';
  end if;

  v_zip := regexp_replace(coalesce(payload->>'zipcode', ''), '[^0-9]', '', 'g');
  if length(v_zip) <> 5 then
    raise exception 'กรุณากรอกรหัสไปรษณีย์ 5 หลัก' using errcode = 'P0001';
  end if;

  v_occ := left(btrim(coalesce(payload->>'occupation', '')), 120);
  if length(v_occ) < 2 then
    raise exception 'กรุณาระบุอาชีพ' using errcode = 'P0001';
  end if;
  v_work := left(btrim(coalesce(payload->>'workplace', '')), 160);
  if v_work = '' then
    raise exception 'กรุณาระบุที่ทำงาน (ถ้าไม่มีใส่ -)' using errcode = 'P0001';
  end if;
  v_income := nullif(regexp_replace(coalesce(payload->>'income', ''), '[^0-9]', '', 'g'), '')::bigint;
  if v_income is null or v_income <= 0 or v_income > 100000000 then
    raise exception 'กรุณากรอกรายได้ต่อเดือน' using errcode = 'P0001';
  end if;

  -- ความยินยอม PDPA: ต้องติ๊กมาจากหน้าเว็บ · เก็บเวลาที่ยินยอม + รุ่นของข้อความ
  if coalesce(payload->>'consent', '') <> 'true' then
    raise exception 'กรุณาติ๊กยินยอมให้เก็บและใช้ข้อมูลส่วนบุคคลก่อนส่ง' using errcode = 'P0001';
  end if;

  select array_agg(distinct c) into v_covers
    from jsonb_array_elements_text(coalesce(payload->'covers', '[]'::jsonb)) c
   where c in ('type1','type2plus','type3','type3plus','act');
  if v_covers is null then v_covers := '{}'; end if;

  v_relation := coalesce(payload->>'relation', 'self');
  if v_relation not in ('self','father','mother','husband','wife','child','other') then
    v_relation := case when v_kind = 'refer' then 'other' else 'self' end;
  end if;
  if v_kind = 'refer' then v_relation := 'other'; end if;

  v_ym := to_char(now() at time zone 'Asia/Bangkok', 'YYMM');
  insert into public.ins_seq (ym, n) values (v_ym, 1)
    on conflict (ym) do update set n = public.ins_seq.n + 1
    returning n into v_n;
  v_no := 'INS-' || v_ym || '-' || lpad(v_n::text, 3, '0');

  v_token := encode(gen_random_bytes(16), 'hex');

  -- ผู้ดูแล: ใครมีใบสะสมน้อยสุดได้ก่อน เสมอกันสุ่ม
  v_assignee := public.ins_pick_assignee();

  insert into public.ins_requests (
    no, kind, emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
    insured_name, addr, moo, road, tambon, amphoe, province, phone_home, phone_mobile,
    relation, relation_note, car_brand, car_model, car_plate, car_year, covers,
    doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note, note,
    upload_token, submit_ip, assigned_to, assigned_at,
    id_card, zipcode, occupation, workplace, income, consent_at, consent_version,
    birth_date
  ) values (
    v_no, v_kind, v_emp_id, v_name, v_dept,
    left(coalesce(payload->>'empBranch', ''), 60), v_verified, v_typedkeep,
    left(v_insured, 120),
    left(coalesce(payload->>'addr', ''), 80),
    left(coalesce(payload->>'moo', ''), 20),
    left(coalesce(payload->>'road', ''), 60),
    left(coalesce(payload->>'tambon', ''), 60),
    left(coalesce(payload->>'amphoe', ''), 60),
    left(coalesce(payload->>'province', ''), 60),
    left(regexp_replace(coalesce(payload->>'phoneHome', ''), '[^0-9+ -]', '', 'g'), 20),
    left(v_mobile, 20),
    v_relation,
    case when v_relation = 'other' then left(coalesce(payload->>'relationNote', ''), 60) else '' end,
    left(coalesce(payload->>'carBrand', ''), 60),
    left(coalesce(payload->>'carModel', ''), 60),
    left(coalesce(payload->>'carPlate', ''), 30),
    left(regexp_replace(coalesce(payload->>'carYear', ''), '[^0-9]', '', 'g'), 10),
    v_covers,
    coalesce((payload->>'docCarReg')::boolean, false),
    coalesce((payload->>'docIdCard')::boolean, false),
    coalesce((payload->>'docOldPolicy')::boolean, false),
    coalesce((payload->>'docRelDoc')::boolean, false),
    case when coalesce((payload->>'docRelDoc')::boolean, false)
         then left(coalesce(payload->>'docRelDocNote', ''), 60) else '' end,
    left(coalesce(payload->>'note', ''), 500),
    v_token, v_ip, v_assignee, case when v_assignee is null then null else now() end,
    v_idcard, v_zip, v_occ, v_work, v_income,
    now(), left(coalesce(payload->>'consentVersion', ''), 40),
    v_birth
  ) returning id into v_id;

  insert into public.ins_submit_log (ip) values (v_ip);

  -- ผู้ดูแล: คืนให้เฉพาะแบบ "พนักงานทำประกันเอง" (หน้าส่งสำเร็จบอกให้พนักงานติดต่อเจ้าหน้าที่คนนี้)
  -- 🔒 แบบแนะนำลูกค้า = ลูกค้าภายนอกเป็นคนกรอก ไม่คืนชื่อ/เบอร์เจ้าหน้าที่ (ขึ้นแค่ "รอติดต่อกลับ")
  if v_kind = 'self' and v_assignee is not null then
    select jsonb_build_object(
             'name',  coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id),
             'phone', s.phone)
      into v_contact
      from public.ins_staff s
      left join public.employees e on e.emp_id = s.emp_id
     where s.emp_id = v_assignee;
  end if;

  return jsonb_build_object(
    'assignee', v_contact,
    'id', v_id, 'no', v_no, 'uploadToken', v_token,
    'empName', v_name, 'empDept', v_dept, 'empVerified', v_verified,
    'insuredName', v_insured, 'phoneMobile', v_mobile, 'covers', to_jsonb(v_covers),
    'kind', v_kind,
    'car', jsonb_build_object('brand', coalesce(payload->>'carBrand',''),
                              'model', coalesce(payload->>'carModel',''),
                              'plate', coalesce(payload->>'carPlate',''))
  );
end;
$$;

-- view ของหลังบ้าน: ต่อท้ายคอลัมน์ใหม่ (create or replace view เพิ่มคอลัมน์ได้เฉพาะท้ายสุด)
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
         consent_at, consent_version, birth_date
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;
