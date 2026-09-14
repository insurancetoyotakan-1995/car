-- =====================================================================
--  ระบบขอทำประกันภัยรถยนต์ · โตโยต้า กาญจนบุรี — สคีมาสำหรับ Supabase
--  วิธีติดตั้ง: เปิด Supabase Dashboard → SQL Editor → วางไฟล์นี้ทั้งไฟล์ → Run
--  ⚠️ แล้วรัน supabase/migrate-2026-09-14-assign.sql ต่อ (แจกผู้ดูแล + เจ้าหน้าที่เห็นเฉพาะใบตัวเอง)
--     ไฟล์นั้นทับ ins_submit / ins_set_status / policy ของเจ้าหน้าที่ในไฟล์นี้
--  รันซ้ำได้ (idempotent) — ใช้ IF NOT EXISTS / DROP ... IF EXISTS ทุกที่
--
--  🔑 หลักความปลอดภัยของไฟล์นี้
--     ทุกตารางเปิด RLS แล้ว "ไม่สร้าง policy ให้ anon เลย" → คนที่ถือ anon key
--     (ซึ่งฝังอยู่ในหน้าเว็บ ใครก็อ่านได้) แตะตารางตรง ๆ ไม่ได้แม้แต่แถวเดียว
--     ทางเข้าเดียวของฟอร์มสาธารณะคือ RPC 3 ตัวท้ายไฟล์ ซึ่งคุมสิ่งที่ทำได้ไว้แคบที่สุด
--     ส่วนเจ้าหน้าที่ (ผู้ใช้ที่ล็อกอิน) อ่าน/อัปเดตสถานะได้ผ่าน policy ของ authenticated
-- =====================================================================

-- pgcrypto = ตัวสร้างกุญแจสุ่ม (gen_random_bytes) — Supabase ติดตั้งไว้ใน schema "extensions"
-- ⚠️ ฟังก์ชันที่เรียกใช้ต้องมี extensions อยู่ใน search_path ด้วย ไม่งั้นจะ "function does not exist"
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1) ทำเนียบพนักงาน (สำหรับค้นชื่อจากรหัส)
--    ⚠️ ส่งขึ้นคลาวด์เฉพาะ รหัส/ชื่อ/แผนก เท่านั้น
--       ไม่ส่งรหัสผ่าน ลายเซ็น ตำแหน่ง หรืออย่างอื่นจากทำเนียบเดิม
-- ---------------------------------------------------------------------
create table if not exists public.employees (
  emp_id  text primary key,
  name    text not null,
  dept    text not null default '',
  active  boolean not null default true
);

-- ---------------------------------------------------------------------
-- 2) ใบคำขอ
--    แตกเป็นคอลัมน์จริง (ไม่เก็บ JSON ก้อนเดียวแบบฝั่ง SQLite เดิม)
--    เพราะ Postgres กรอง/เรียง/ทำรายงานจากคอลัมน์ได้ดีกว่ามาก
-- ---------------------------------------------------------------------
create table if not exists public.ins_requests (
  id              uuid primary key default gen_random_uuid(),
  no              text not null unique,              -- INS-2609-001
  kind            text not null check (kind in ('self','refer')),

  -- พนักงานผู้ยื่น/ผู้แนะนำ (มาจากช่องที่ผู้กรอกพิมพ์เอง แล้ว RPC ตรวจกับทำเนียบ)
  emp_id          text not null,
  emp_name        text not null,
  emp_dept        text not null default '',
  emp_branch      text not null default '',
  emp_verified    boolean not null default false,     -- true = รหัสตรงกับทำเนียบ
  emp_typed_name  text,                               -- ชื่อที่พิมพ์มา ถ้าไม่ตรงกับทำเนียบ

  -- ผู้เอาประกัน
  insured_name    text not null,
  addr            text not null default '',
  moo             text not null default '',
  road            text not null default '',
  tambon          text not null default '',
  amphoe          text not null default '',
  province        text not null default '',
  phone_home      text not null default '',
  phone_mobile    text not null,
  relation        text not null default 'self'
                  check (relation in ('self','father','mother','husband','wife','child','other')),
  relation_note   text not null default '',

  -- รถ + ความคุ้มครอง
  car_brand       text not null default '',
  car_model       text not null default '',
  car_plate       text not null default '',
  car_year        text not null default '',
  -- ไม่บังคับแล้ว (ผู้ใช้ถอดแผง "รถที่ทำประกันภัย" ออกจากฟอร์ม 2026-09-12)
  -- เจ้าหน้าที่สอบถามประเภทความคุ้มครองตอนโทรกลับแทน
  covers          text[] not null default '{}',

  -- เอกสารที่แจ้งว่ามี (ติ๊กในฟอร์ม — คนละเรื่องกับไฟล์ที่อัปโหลดจริง)
  doc_car_reg     boolean not null default false,
  doc_id_card     boolean not null default false,
  doc_old_policy  boolean not null default false,
  doc_rel_doc     boolean not null default false,
  doc_rel_note    text not null default '',

  note            text not null default '',

  -- สถานะการติดตามของเจ้าหน้าที่
  status          text not null default 'new'
                  check (status in ('new','contacted','quoted','done','cancelled')),
  status_note     text not null default '',

  -- กุญแจแนบไฟล์ประจำใบ (คนที่เพิ่งยื่นยังไม่มีบัญชี แต่ต้องแนบเอกสารได้)
  -- 🔑 ไม่มี policy ไหนให้ anon อ่านคอลัมน์นี้ — ค่าถูกคืนครั้งเดียวตอนยื่นผ่าน RPC
  upload_token    text not null,
  submit_ip       text,                               -- ไว้ตามรอยกรณีถูกยิงใบขยะ
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists ins_requests_created_idx on public.ins_requests (created_at desc);
create index if not exists ins_requests_status_idx  on public.ins_requests (status);
create index if not exists ins_requests_emp_idx     on public.ins_requests (emp_id);

-- ---------------------------------------------------------------------
-- 3) ไฟล์แนบ (metadata — ไฟล์จริงอยู่ใน Storage bucket 'ins-files')
-- ---------------------------------------------------------------------
create table if not exists public.ins_files (
  id          uuid primary key default gen_random_uuid(),
  req_id      uuid not null references public.ins_requests(id) on delete cascade,
  name        text not null,
  size        integer not null default 0,
  mime        text not null default '',
  tag         text not null default '',               -- carReg / idCard / oldPolicy / relDoc
  path        text not null,                          -- พาธใน bucket
  created_at  timestamptz not null default now()
);
create index if not exists ins_files_req_idx on public.ins_files (req_id);

-- ---------------------------------------------------------------------
-- 4) เลขรันต่อเดือน — INS-<ปี ค.ศ. 2 หลัก><เดือน>-<เลขรัน 3 หลัก>
-- ---------------------------------------------------------------------
create table if not exists public.ins_seq (
  ym  text primary key,
  n   integer not null default 0
);

-- ---------------------------------------------------------------------
-- 5) บันทึกการยื่น (ใช้ทำเพดานกันยิงรัว)
-- ---------------------------------------------------------------------
create table if not exists public.ins_submit_log (
  id          bigserial primary key,
  ip          text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists ins_submit_log_idx on public.ins_submit_log (ip, created_at desc);

-- ---------------------------------------------------------------------
-- 6) เจ้าหน้าที่ประกันที่เข้าหลังบ้านได้ (staff.html)
--    🔑 เข้าได้เฉพาะแผนกประกัน: ต้อง "มีบัญชี Auth" + "รหัสอยู่ในตารางนี้" ทั้งคู่
--    บัญชี Auth ตั้งอีเมลเป็น <รหัสพนักงาน>@staff.toyotakan (หน้าเว็บให้พิมพ์แค่รหัส)
--    เพิ่มคน:   insert into public.ins_staff (emp_id, note) values ('11001246', 'ชื่อ');
--    ปิดสิทธิ์: update public.ins_staff set active = false where emp_id = '...';
--    บัญชีกลางที่ใช้อีเมลจริง: ใส่อีเมลเต็มใน emp_id เช่น ('insurance@toyotakan.co.th', 'บัญชีกลางแผนกประกัน')
-- ---------------------------------------------------------------------
create table if not exists public.ins_staff (
  emp_id      text primary key,
  note        text not null default '',
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ผู้ใช้ที่ล็อกอินอยู่ = เจ้าหน้าที่ประกันหรือไม่
-- security definer → อ่าน ins_staff ได้ ทั้งที่ตารางไม่มี policy ให้ใครเลย
create or replace function public.is_ins_staff()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ins_staff s
     where s.active
       -- รหัสพนักงาน → <รหัส>@staff.toyotakan · ใส่อีเมลเต็มใน emp_id ได้ด้วย (บัญชีกลาง เช่น insurance@toyotakan.co.th)
       and lower(coalesce(auth.jwt()->>'email', '')) in (lower(s.emp_id) || '@staff.toyotakan', lower(s.emp_id))
  );
$$;
revoke all on function public.is_ins_staff() from public;
grant execute on function public.is_ins_staff() to authenticated;

-- =====================================================================
--  RLS — เปิดทุกตาราง
--  🔒 anon ไม่ได้ policy อะไรเลย = แตะตารางตรง ๆ ไม่ได้ (ทางเข้าคือ RPC เท่านั้น)
-- =====================================================================
alter table public.employees      enable row level security;
alter table public.ins_requests   enable row level security;
alter table public.ins_files      enable row level security;
alter table public.ins_seq        enable row level security;
alter table public.ins_submit_log enable row level security;
alter table public.ins_staff      enable row level security;   -- ไม่มี policy = อ่านตรงไม่ได้เลย

-- เจ้าหน้าที่ = ผู้ใช้ Auth ที่รหัสอยู่ใน ins_staff (แผนกประกันเท่านั้น)
-- 🔑 บัญชี Auth ของคนอื่น (หรือบัญชีที่หลุดสมัครเข้ามา) จะไม่เห็นอะไรเลย
drop policy if exists staff_read_requests on public.ins_requests;
create policy staff_read_requests on public.ins_requests
  for select to authenticated using (public.is_ins_staff());

drop policy if exists staff_update_requests on public.ins_requests;
create policy staff_update_requests on public.ins_requests
  for update to authenticated using (public.is_ins_staff()) with check (public.is_ins_staff());

drop policy if exists staff_delete_requests on public.ins_requests;
create policy staff_delete_requests on public.ins_requests
  for delete to authenticated using (public.is_ins_staff());

drop policy if exists staff_read_files on public.ins_files;
create policy staff_read_files on public.ins_files
  for select to authenticated using (public.is_ins_staff());

drop policy if exists staff_delete_files on public.ins_files;
create policy staff_delete_files on public.ins_files
  for delete to authenticated using (public.is_ins_staff());

drop policy if exists staff_read_employees on public.employees;
create policy staff_read_employees on public.employees
  for select to authenticated using (public.is_ins_staff());

-- ⚠️ upload_token ต้องไม่หลุดไปกับ select ของเจ้าหน้าที่ด้วย
--    Postgres ไม่มี column-level RLS → ใช้ view ที่ไม่มีคอลัมน์นั้นให้หน้าเว็บเรียกแทน
drop view if exists public.ins_requests_view;
create view public.ins_requests_view
with (security_invoker = true) as
  select id, no, kind,
         emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
         insured_name, addr, moo, road, tambon, amphoe, province,
         phone_home, phone_mobile, relation, relation_note,
         car_brand, car_model, car_plate, car_year, covers,
         doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note,
         note, status, status_note, created_at, updated_at
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;

-- =====================================================================
--  RPC — ทางเข้าเดียวของฟอร์มสาธารณะ
--  ทุกตัวเป็น security definer จึงข้าม RLS ได้ แต่ทำได้แค่สิ่งที่เขียนไว้ในตัวมันเอง
-- =====================================================================

-- ---------------------------------------------------------------------
--  ค้นชื่อพนักงานจากรหัส
--  🔒 คืนแค่ ชื่อ + แผนก และรับรหัสได้ทีละตัว → anon ดึงรายชื่อทั้งองค์กรไปไม่ได้
-- ---------------------------------------------------------------------
create or replace function public.ins_lookup_emp(p_emp_id text)
returns table (found boolean, name text, dept text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
  r    record;
begin
  if length(v_id) < 4 then
    return query select false, ''::text, ''::text;
    return;
  end if;
  select e.name, e.dept into r from public.employees e
   where e.emp_id = v_id and e.active is true;
  if not found then
    return query select false, ''::text, ''::text;
  else
    return query select true, r.name, r.dept;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
--  ยื่นคำขอ
--  รับ jsonb ก้อนเดียวจากฟอร์ม → ล้างค่า → ออกเลขที่ → คืน id + เลขที่ + กุญแจแนบไฟล์
-- ---------------------------------------------------------------------
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
  -- ตัดคำนำหน้าชื่อ (กติกาเดียวกับ stripTitle ฝั่ง Node — เรียงตัวยาวก่อนตัวสั้น
  -- ไม่งั้น "นางสาว" จะถูก "นาง" กินก่อน)
  c_title     text := '^\s*(ว่าที่\s*ร\.?ต\.?(อ|ท|ญ)?\.?|ว่าที่\s*ร\.?อ\.?|นางสาว|น\.ส\.|นาง|นาย|ดร\.|ผศ\.|รศ\.|ศ\.|คุณ)\s*';
begin
  -- เพดานกันยิงรัว: 40 ใบ/10 นาที ต่อ IP
  -- (ตั้ง 10 ตอนแรกแล้วเจอว่าตึงเกินไป — เจ้าหน้าที่คีย์ใบจากกองกระดาษจะโดนกั้น)
  select count(*) into v_recent from public.ins_submit_log
   where ip = v_ip and created_at > now() - interval '10 minutes';
  if v_recent >= 40 then
    raise exception 'ยื่นคำขอถี่เกินไป กรุณารอสักครู่แล้วลองใหม่' using errcode = 'P0001';
  end if;

  -- ปิดกับดักบอท: ช่องที่คนมองไม่เห็น ถ้ามีค่ามาแปลว่าไม่ใช่คนกรอก
  if coalesce(payload->>'hp', '') <> '' then
    raise exception 'ไม่สามารถรับคำขอนี้ได้' using errcode = 'P0001';
  end if;

  v_kind := coalesce(payload->>'kind', 'self');
  if v_kind not in ('self','refer') then v_kind := 'self'; end if;

  -- ผู้ยื่น: เจอในทำเนียบ → ใช้ชื่อ/แผนกจากระบบทับที่พิมพ์มา (กันกรอกรหัสถูกแต่ชื่อมั่ว)
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
    -- แผนก: ทำเนียบชนะ · ทำเนียบไม่มีแผนก → ใช้ที่เลือกในฟอร์ม
    v_dept := coalesce(nullif(v_emp.dept, ''), left(btrim(coalesce(payload->>'empDept', '')), 60));
    if v_typed <> '' and v_typed <> v_emp.name then v_typedkeep := v_typed; end if;
  else
    if v_typed = '' then
      raise exception 'กรุณากรอกชื่อ-นามสกุลพนักงาน' using errcode = 'P0001';
    end if;
    v_name := v_typed;
    -- ไม่เจอในทำเนียบ → เก็บแผนกที่เลือกในฟอร์ม (เจ้าหน้าที่ใช้ตามตัวผู้แนะนำ)
    v_dept := left(btrim(coalesce(payload->>'empDept', '')), 60);
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

  -- ที่อยู่: บังคับ บ้านเลขที่ / ตำบล / อำเภอ / จังหวัด (หมู่ / ถนน เว้นว่างได้)
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

  -- ความคุ้มครอง: เก็บเฉพาะค่าที่รู้จัก (ค่าแปลกปลอมถูกทิ้งเงียบ ไม่ถือเป็น error)
  select array_agg(distinct c) into v_covers
    from jsonb_array_elements_text(coalesce(payload->'covers', '[]'::jsonb)) c
   where c in ('type1','type2plus','type3','type3plus','act');
  -- ไม่บังคับแล้ว — ฟอร์มไม่มีช่องนี้ (เจ้าหน้าที่สอบถามตอนโทรกลับ)
  if v_covers is null then v_covers := '{}'; end if;

  v_relation := coalesce(payload->>'relation', 'self');
  if v_relation not in ('self','father','mother','husband','wife','child','other') then
    v_relation := case when v_kind = 'refer' then 'other' else 'self' end;
  end if;
  if v_kind = 'refer' then v_relation := 'other'; end if;

  -- เลขที่: แยกชุดตามเดือน (เวลาไทย UTC+7 — ต้องระบุโซนเวลา ไม่งั้นช่วงเช้ามืดได้เดือนก่อนหน้า)
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

-- ---------------------------------------------------------------------
--  บันทึก metadata ของไฟล์ที่เพิ่งอัปโหลดเข้า Storage
--  🔑 ต้องส่งกุญแจของใบนั้นมาด้วย และกุญแจหมดอายุ 60 นาทีหลังยื่น
--     → เอากุญแจใบอื่นมาใช้ หรือมาแนบทีหลังเป็นวัน ทำไม่ได้
-- ---------------------------------------------------------------------
create or replace function public.ins_add_file(
  p_req uuid, p_token text, p_name text, p_size integer,
  p_mime text, p_tag text, p_path text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r       record;
  v_count integer;
begin
  select id, created_at into r from public.ins_requests
   where id = p_req and upload_token = p_token
     and created_at > now() - interval '60 minutes';
  if not found then
    raise exception 'ไม่พบใบคำขอ หรือหมดเวลาแนบไฟล์แล้ว' using errcode = 'P0001';
  end if;

  select count(*) into v_count from public.ins_files where req_id = p_req;
  if v_count >= 8 then
    raise exception 'แนบได้สูงสุด 8 ไฟล์ต่อใบ' using errcode = 'P0001';
  end if;

  -- รับเฉพาะชนิดที่ฟอร์มอนุญาต (กันคนยิง RPC ตรงเพื่อบันทึกพาธอะไรก็ได้)
  if p_mime not in ('application/pdf','image/jpeg','image/png') then
    raise exception 'รับเฉพาะไฟล์ PDF, JPG หรือ PNG เท่านั้น' using errcode = 'P0001';
  end if;
  -- พาธต้องอยู่ใต้โฟลเดอร์ของใบนี้เท่านั้น
  if p_path is null or p_path not like (p_req::text || '/%') then
    raise exception 'ตำแหน่งไฟล์ไม่ถูกต้อง' using errcode = 'P0001';
  end if;

  insert into public.ins_files (req_id, name, size, mime, tag, path)
  values (p_req, left(coalesce(p_name,'เอกสารแนบ'), 120), greatest(coalesce(p_size,0), 0),
          p_mime, left(coalesce(p_tag,''), 20), p_path);

  update public.ins_requests set updated_at = now() where id = p_req;

  return jsonb_build_object('ok', true, 'files', (
    select coalesce(jsonb_agg(jsonb_build_object('name', name, 'size', size, 'mime', mime, 'tag', tag)
           order by created_at), '[]'::jsonb) from public.ins_files where req_id = p_req));
end;
$$;

-- ---------------------------------------------------------------------
--  เจ้าหน้าที่: เปลี่ยนสถานะการติดตาม (ต้องล็อกอิน)
-- ---------------------------------------------------------------------
create or replace function public.ins_set_status(p_req uuid, p_status text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  if p_status not in ('new','contacted','quoted','done','cancelled') then
    raise exception 'สถานะไม่ถูกต้อง' using errcode = 'P0001';
  end if;
  update public.ins_requests
     set status = p_status, status_note = left(coalesce(p_note,''), 300), updated_at = now()
   where id = p_req;
  if not found then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
--  สิทธิ์เรียก RPC
-- ---------------------------------------------------------------------
revoke all on function public.ins_lookup_emp(text) from public;
revoke all on function public.ins_submit(jsonb) from public;
revoke all on function public.ins_add_file(uuid, text, text, integer, text, text, text) from public;
revoke all on function public.ins_set_status(uuid, text, text) from public;

grant execute on function public.ins_lookup_emp(text) to anon, authenticated;
grant execute on function public.ins_submit(jsonb) to anon, authenticated;
grant execute on function public.ins_add_file(uuid, text, text, integer, text, text, text) to anon, authenticated;
grant execute on function public.ins_set_status(uuid, text, text) to authenticated;

-- =====================================================================
--  Storage — bucket สำหรับไฟล์แนบ
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ins-files', 'ins-files', false, 10485760,
        array['application/pdf','image/jpeg','image/png'])
on conflict (id) do update
  set public = false,
      file_size_limit = 10485760,
      allowed_mime_types = array['application/pdf','image/jpeg','image/png'];

-- anon: "อัปโหลดได้ อ่านไม่ได้ ลบไม่ได้"
-- 🔑 พาธใช้ uuid ของใบเป็นโฟลเดอร์ — uuid เดาไม่ได้ จึงแนบใส่ใบคนอื่นไม่ได้ในทางปฏิบัติ
--    และเพราะอ่านไม่ได้ ไฟล์ที่อัปแล้วจึงไม่กลายเป็นที่ฝากไฟล์สาธารณะ
drop policy if exists ins_files_anon_insert on storage.objects;
create policy ins_files_anon_insert on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'ins-files');

drop policy if exists ins_files_staff_read on storage.objects;
create policy ins_files_staff_read on storage.objects
  for select to authenticated using (bucket_id = 'ins-files' and public.is_ins_staff());

drop policy if exists ins_files_staff_delete on storage.objects;
create policy ins_files_staff_delete on storage.objects
  for delete to authenticated using (bucket_id = 'ins-files' and public.is_ins_staff());
