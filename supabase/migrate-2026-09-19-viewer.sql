-- ============================================================================
-- บัญชี "ดูอย่างเดียว" สำหรับฝ่ายบุคคล (2026-09-19)
--   hr@toyotakan.co.th → เข้าหน้า staff.html ได้ · เห็นเฉพาะใบ "ปิดการขาย" (status = 'done')
--   ดูข้อมูล/เอกสารแนบ/พิมพ์ใบคำขอและใบค่าคอมได้ · แก้ไขอะไรไม่ได้เลย
--
--   🔑 เก็บในตารางแยก ins_viewers — ไม่ใส่ใน ins_staff
--      ทุกฟังก์ชันที่ "แก้ข้อมูล" (ins_set_quote / ins_set_status / ins_assign / นโยบาย update/delete)
--      ตรวจด้วย is_ins_staff() / ins_can_see() / is_ins_admin() ซึ่งอ่านจาก ins_staff อย่างเดียว
--      → บัญชีในตารางนี้ถูกปฏิเสธทุกทางโดยอัตโนมัติ · ไม่อยู่ในกองแจกงาน · ไม่ได้รับ LINE
--   🔑 สิทธิ์อ่านเพิ่มแบบ "นโยบายใหม่แยก" (Postgres รวมนโยบาย select แบบ OR) — ไม่แตะนโยบายเดิมของเจ้าหน้าที่
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องสร้างบัญชีเข้าสู่ระบบ hr@toyotakan.co.th เองใน Supabase → Authentication → Users → Add user
--    (ตั้งรหัสผ่านเอง · ติ๊ก Auto Confirm User)
-- ============================================================================

begin;

-- ---------- 1) รายชื่อบัญชีดูอย่างเดียว ----------
create table if not exists public.ins_viewers (
  email       text primary key,            -- อีเมลบัญชี Supabase Auth (ตัวเล็ก)
  note        text not null default '',    -- ชื่อที่แสดงบนหน้าเว็บ
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table public.ins_viewers enable row level security;     -- ไม่มี policy = อ่านได้เฉพาะฟังก์ชัน security definer
revoke all on public.ins_viewers from anon, authenticated;

insert into public.ins_viewers (email, note) values ('hr@toyotakan.co.th', 'ฝ่ายบุคคล')
on conflict (email) do update set note = excluded.note, active = true;

-- ---------- 2) ตัวช่วย ----------
create or replace function public.ins_is_viewer()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ins_viewers v
     where v.active and lower(v.email) = lower(coalesce(auth.jwt()->>'email', ''))
  );
$$;

-- ใบนี้ปิดการขายแล้วหรือยัง (security definer — ใช้ในนโยบายโดยไม่วนกลับมาเจอ RLS ของตารางเดิม)
create or replace function public.ins_req_done(p_req uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.ins_requests r where r.id = p_req and r.status = 'done');
$$;

-- ไฟล์ใน bucket นี้เป็นของใบที่ปิดการขายแล้วหรือยัง (จับคู่ด้วยพาธที่บันทึกไว้ใน ins_files)
create or replace function public.ins_file_done(p_path text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ins_files f join public.ins_requests r on r.id = f.req_id
     where f.path = p_path and r.status = 'done'
  );
$$;

-- หน้าเว็บถามว่าเป็นบัญชีดูอย่างเดียวไหม (ไม่ใช่ = null)
create or replace function public.ins_viewer_me()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object('empId', v.email, 'role', 'viewer', 'name', coalesce(nullif(v.note, ''), v.email))
    from public.ins_viewers v
   where v.active and lower(v.email) = lower(coalesce(auth.jwt()->>'email', ''))
   limit 1;
$$;

-- ชื่อเจ้าหน้าที่ประกัน (แสดง "ผู้ดูแล" บนใบคำขอ/ใบค่าคอม) — เฉพาะบัญชีดูอย่างเดียว
create or replace function public.ins_viewer_agents()
returns table (emp_id text, name text)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.ins_is_viewer() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์' using errcode = 'P0001';
  end if;
  return query
    select s.emp_id, coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id)
      from public.ins_staff s left join public.employees e on e.emp_id = s.emp_id;
end;
$$;

-- ---------- 3) สิทธิ์อ่าน (เฉพาะใบปิดการขาย) ----------
drop policy if exists viewer_read_done on public.ins_requests;
create policy viewer_read_done on public.ins_requests
  for select to authenticated using (public.ins_is_viewer() and status = 'done');

drop policy if exists viewer_read_files on public.ins_files;
create policy viewer_read_files on public.ins_files
  for select to authenticated using (public.ins_is_viewer() and public.ins_req_done(req_id));

drop policy if exists ins_files_viewer_read on storage.objects;
create policy ins_files_viewer_read on storage.objects
  for select to authenticated using (bucket_id = 'ins-files' and public.ins_is_viewer() and public.ins_file_done(name));

-- ---------- 4) สิทธิ์เรียกฟังก์ชัน ----------
revoke all on function public.ins_is_viewer()        from public, anon;
revoke all on function public.ins_req_done(uuid)     from public, anon;
revoke all on function public.ins_file_done(text)    from public, anon;
revoke all on function public.ins_viewer_me()        from public, anon;
revoke all on function public.ins_viewer_agents()    from public, anon;
grant execute on function public.ins_is_viewer()     to authenticated;
grant execute on function public.ins_req_done(uuid)  to authenticated;
grant execute on function public.ins_file_done(text) to authenticated;
grant execute on function public.ins_viewer_me()     to authenticated;
grant execute on function public.ins_viewer_agents() to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select (select count(*) from public.ins_viewers where active) as viewers,
--          (select count(*) from pg_policies
--            where policyname in ('viewer_read_done', 'viewer_read_files', 'ins_files_viewer_read')) as policies,
--          (select count(*) from public.ins_staff where lower(emp_id) = 'hr@toyotakan.co.th') as in_staff;
--   -- ต้องได้ viewers = 1 · policies = 3 · in_staff = 0 (ต้องไม่อยู่ในตารางเจ้าหน้าที่)
-- ============================================================================
