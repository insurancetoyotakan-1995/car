-- =====================================================================
--  migrate 2026-09-14 (2) : ให้บัญชีกลาง insurance@toyotakan.co.th เข้าหลังบ้านได้
--  is_ins_staff() รับอีเมลเต็มที่ใส่ไว้ใน ins_staff.emp_id ได้ด้วย
--  (รหัสพนักงานไม่มี @ จึงไม่มีทางไปตรงกับอีเมลจริงของใครโดยบังเอิญ)
--  วิธีใช้: SQL Editor → วางทั้งไฟล์ → Run (รันซ้ำได้)
-- =====================================================================

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

insert into public.ins_staff (emp_id, note) values ('insurance@toyotakan.co.th', 'บัญชีกลางแผนกประกัน')
on conflict (emp_id) do update set note = excluded.note, active = true;
