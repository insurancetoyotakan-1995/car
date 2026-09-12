-- =====================================================================
--  แก้ฐานข้อมูลให้รับคำขอที่ "ไม่ระบุประเภทความคุ้มครอง"
--  (ผู้ใช้ถอดแผง "รถที่ทำประกันภัย" ออกจากฟอร์ม 2026-09-12
--   เจ้าหน้าที่จะสอบถามข้อมูลรถและความคุ้มครองตอนโทรกลับแทน)
--
--  ⚠️ ต้องรันไฟล์นี้ก่อน ไม่งั้นฟอร์มใหม่จะส่งคำขอไม่ได้เลย
--     (ของเดิมบังคับให้มีความคุ้มครองอย่างน้อย 1 อย่าง)
--
--  วิธีรัน: Supabase Dashboard → SQL Editor → New query → วางทั้งไฟล์ → Run
--  รันซ้ำได้ · ข้อมูลใบที่มีอยู่แล้วไม่ถูกแตะ
-- =====================================================================

-- 1) ปลดเงื่อนไข "ต้องมีความคุ้มครองอย่างน้อย 1 อย่าง" ออกจากตาราง
--    ชื่อ constraint ที่ Postgres ตั้งให้อัตโนมัติคือ <ตาราง>_<คอลัมน์>_check
alter table public.ins_requests drop constraint if exists ins_requests_covers_check;
alter table public.ins_requests alter column covers set default '{}';

-- 2) แก้ RPC ให้ไม่ปฏิเสธคำขอที่ไม่มีความคุ้มครอง
--    (แก้แค่บล็อกเดียวไม่ได้ ต้องประกาศฟังก์ชันใหม่ทั้งตัว)
create or replace function public.ins_submit(payload jsonb)
returns jsonb
language plpgsql
security definer
-- ⚠️ ต้องมี extensions ใน search_path ด้วย เพราะเรียก gen_random_bytes (pgcrypto)
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
  c_title     text := '^\s*(ว่าที่\s*ร\.?ต\.?(อ|ท|ญ)?\.?|ว่าที่\s*ร\.?อ\.?|นางสาว|น\.ส\.|นาง|นาย|ดร\.|ผศ\.|รศ\.|ศ\.|คุณ)\s*';
begin
  -- เพดานกันยิงรัว: 40 ใบ/10 นาที ต่อ IP
  select count(*) into v_recent from public.ins_submit_log
   where ip = v_ip and created_at > now() - interval '10 minutes';
  if v_recent >= 40 then
    raise exception 'ยื่นคำขอถี่เกินไป กรุณารอสักครู่แล้วลองใหม่' using errcode = 'P0001';
  end if;

  -- กับดักบอท: ช่องที่คนมองไม่เห็น ถ้ามีค่ามาแปลว่าไม่ใช่คนกรอก
  if coalesce(payload->>'hp', '') <> '' then
    raise exception 'ไม่สามารถรับคำขอนี้ได้' using errcode = 'P0001';
  end if;

  v_kind := coalesce(payload->>'kind', 'self');
  if v_kind not in ('self','refer') then v_kind := 'self'; end if;

  -- ผู้ยื่น: เจอในทำเนียบ → ใช้ชื่อ/แผนกจากระบบทับที่พิมพ์มา
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
    v_dept := coalesce(v_emp.dept, '');
    if v_typed <> '' and v_typed <> v_emp.name then v_typedkeep := v_typed; end if;
  else
    if v_typed = '' then
      raise exception 'กรุณากรอกชื่อ-นามสกุลพนักงาน' using errcode = 'P0001';
    end if;
    v_name := v_typed;
    v_dept := '';
  end if;

  -- ผู้เอาประกัน
  v_insured := btrim(regexp_replace(coalesce(payload->>'insuredName', ''), c_title, ''));
  if v_insured = '' then
    raise exception 'กรุณากรอกชื่อผู้ทำประกันภัย' using errcode = 'P0001';
  end if;
  v_mobile := regexp_replace(coalesce(payload->>'phoneMobile', ''), '[^0-9+ -]', '', 'g');
  if length(regexp_replace(v_mobile, '[^0-9]', '', 'g')) < 9 then
    raise exception 'กรุณากรอกเบอร์โทรศัพท์มือถือให้ครบ' using errcode = 'P0001';
  end if;

  -- ความคุ้มครอง: เก็บเฉพาะค่าที่รู้จัก · 🔑 ไม่บังคับแล้ว (ฟอร์มไม่มีช่องนี้)
  select array_agg(distinct c) into v_covers
    from jsonb_array_elements_text(coalesce(payload->'covers', '[]'::jsonb)) c
   where c in ('type1','type2plus','type3','type3plus','act');
  if v_covers is null then v_covers := '{}'; end if;

  v_relation := coalesce(payload->>'relation', 'self');
  if v_relation not in ('self','father','mother','husband','wife','child','other') then
    v_relation := case when v_kind = 'refer' then 'other' else 'self' end;
  end if;
  if v_kind = 'refer' then v_relation := 'other'; end if;

  -- เลขที่: แยกชุดตามเดือน (เวลาไทย UTC+7)
  v_ym := to_char(now() at time zone 'Asia/Bangkok', 'YYMM');
  insert into public.ins_seq (ym, n) values (v_ym, 1)
    on conflict (ym) do update set n = public.ins_seq.n + 1
    returning n into v_n;
  v_no := 'INS-' || v_ym || '-' || lpad(v_n::text, 3, '0');

  v_token := encode(gen_random_bytes(16), 'hex');

  insert into public.ins_requests (
    no, kind, emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
    insured_name, addr, moo, road, tambon, amphoe, province, phone_home, phone_mobile,
    relation, relation_note, car_brand, car_model, car_plate, car_year, covers,
    doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note, note,
    upload_token, submit_ip
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
    v_token, v_ip
  ) returning id into v_id;

  insert into public.ins_submit_log (ip) values (v_ip);

  return jsonb_build_object(
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

-- สิทธิ์เรียก (ประกาศใหม่แล้วต้อง grant ใหม่)
revoke all on function public.ins_submit(jsonb) from public;
grant execute on function public.ins_submit(jsonb) to anon, authenticated;
