-- =====================================================================
--  migrate 2026-09-14 : หลังบ้าน (staff.html) เข้าได้เฉพาะเจ้าหน้าที่ประกัน
--  - เพิ่มตาราง ins_staff + ฟังก์ชัน is_ins_staff()
--  - ทุก policy ของเจ้าหน้าที่ต้องเป็นรหัสที่อยู่ใน ins_staff (เดิมใครล็อกอินก็เห็นหมด)
--  - login ด้วยรหัสพนักงาน: บัญชี Auth ใช้อีเมล <รหัส>@staff.toyotakan
--  วิธีใช้: SQL Editor → วางทั้งไฟล์ → Run (รันซ้ำได้)
--          แล้วรัน supabase/ins-staff.sql (รายชื่อ · สร้างด้วย scripts/export-ins-staff.cjs)
--  ⚠️ push หน้าเว็บก่อน แล้วค่อยรันไฟล์นี้
-- =====================================================================

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
       and lower(coalesce(auth.jwt()->>'email', '')) = lower(s.emp_id) || '@staff.toyotakan'
  );
$$;
revoke all on function public.is_ins_staff() from public;
grant execute on function public.is_ins_staff() to authenticated;

alter table public.ins_staff enable row level security;

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

drop policy if exists ins_files_staff_read on storage.objects;
create policy ins_files_staff_read on storage.objects
  for select to authenticated using (bucket_id = 'ins-files' and public.is_ins_staff());

drop policy if exists ins_files_staff_delete on storage.objects;
create policy ins_files_staff_delete on storage.objects
  for delete to authenticated using (bucket_id = 'ins-files' and public.is_ins_staff());
