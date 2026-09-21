-- ============================================================================
-- พักเจ้าหน้าที่ออกจากการแจกงานอัตโนมัติ (2026-09-21)
--
--   ผู้ใช้สั่ง: ตัด สมชัย (11001032) กับ กุลธิภัสร์ (11001246) ออกจากการแจกงาน
--
--   🔑 "ตัดออกจากการแจก" ≠ "ปิดสิทธิ์" — ไฟล์นี้ทำแค่หยุดจ่ายใบใหม่ให้เท่านั้น
--      • ใบที่ถืออยู่แล้วยังเป็นของเขา ไม่ถูกย้ายไปไหน
--      • ยังเข้าหลังบ้านดูใบตัวเองและปิดการขายได้ตามปกติ
--      • บัญชีกลางยังเลือกมอบใบให้เขาด้วยมือได้ (ins_assign ไม่ถูกแตะ)
--      ถ้าต้องการ "ตัดสิทธิ์เข้าระบบ" จริง ๆ ให้ใช้:
--        update public.ins_staff set active = false where emp_id in ('11001032','11001246');
--
--   ทำไมใช้คอลัมน์ใหม่ ไม่ใช่เปลี่ยน role: ins_staff_role_chk อนุญาตแค่ 'agent' กับ 'admin'
--   และ role = admin จะกลายเป็นบัญชีกลางเห็นทุกใบ ซึ่งไม่ใช่สิ่งที่ต้องการ
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-21-brand.sql
-- ============================================================================

begin;

-- ---------- 1) ธงรับงานใหม่ ----------
alter table public.ins_staff
  add column if not exists takes_new boolean not null default true;

comment on column public.ins_staff.takes_new is
  'false = ไม่รับใบใหม่จากการแจกอัตโนมัติ (ใบเดิมยังอยู่ · ยังเข้าระบบได้ · บัญชีกลางยังมอบด้วยมือได้)';

-- ---------- 2) ตัวแจกงาน: ข้ามคนที่พักอยู่ ----------
--   เติม s.takes_new ครบทั้ง 3 ทาง — ไม่งั้นพนักงานที่เคยเป็นลูกค้าของเขาจะยังวิ่งกลับไปหา
create or replace function public.ins_pick_assignee(p_emp text, p_kind text, p_brand text default 'toyota')
returns text
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v  text;
  vb text := public.ins_brand(p_brand);
begin
  -- 🔑 ล็อกกันยื่นพร้อมกัน 2 ใบแล้วได้คนเดียวกัน (ค้างจนจบทรานแซกชันของ ins_submit)
  perform pg_advisory_xact_lock(hashtext('ins_pick_assignee'));

  if p_kind = 'self' and coalesce(p_emp, '') <> '' then
    -- 1) ใบล่าสุดในระบบนี้ (แบรนด์เดียวกัน)
    select r.assigned_to into v
      from public.ins_requests r
      join public.ins_staff s on s.emp_id = r.assigned_to and s.active and s.role = 'agent' and s.takes_new
     where r.emp_id = p_emp and r.brand = vb and r.kind = 'self' and r.status <> 'cancelled'
     order by r.created_at desc
     limit 1;
    if v is not null then return v; end if;

    -- 2) ข้อมูลกรมธรรม์เดิมจาก Excel
    select o.agent_emp_id into v
      from public.ins_emp_owner o
      join public.ins_staff s on s.emp_id = o.agent_emp_id and s.active and s.role = 'agent' and s.takes_new
     where o.emp_id = p_emp and o.brand = vb;
    if v is not null then return v; end if;
  end if;

  -- 3) ใครมีใบสะสมน้อยสุดได้ก่อน เสมอกันสุ่ม (นับรวมทุกแบรนด์ — เจ้าหน้าที่ทีมเดียวกัน)
  select s.emp_id into v
    from public.ins_staff s
    left join public.ins_requests r
           on r.assigned_to = s.emp_id and r.status <> 'cancelled'
   where s.active and s.role = 'agent' and s.takes_new
   group by s.emp_id
   order by count(r.id), random()
   limit 1;
  return v;
end;
$$;
revoke all on function public.ins_pick_assignee(text, text, text) from public, anon, authenticated;

-- ---------- 3) หน้าเจ้าหน้าที่เห็นว่าใครพักอยู่ ----------
--   เปลี่ยนชนิดที่คืน → ต้อง drop ก่อน (create or replace เปลี่ยนคอลัมน์ผลลัพธ์ไม่ได้)
drop function if exists public.ins_agents();
create or replace function public.ins_agents()
returns table (emp_id text, name text, active_count bigint, total_count bigint, takes_new boolean)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_ins_admin() then
    raise exception 'เฉพาะบัญชีผู้ดูแล' using errcode = 'P0001';
  end if;
  return query
    select s.emp_id,
           coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id),
           count(r.id) filter (where r.status <> 'cancelled'),
           count(r.id),
           s.takes_new
      from public.ins_staff s
      left join public.employees e on e.emp_id = s.emp_id and e.brand = 'toyota'
      left join public.ins_requests r on r.assigned_to = s.emp_id
     where s.active and s.role = 'agent'
     group by s.emp_id, e.name, s.note, s.takes_new
     order by 2;
end;
$$;
revoke all on function public.ins_agents() from public, anon;
grant execute on function public.ins_agents() to authenticated;

-- ---------- 4) ตัด 2 คนนี้ออกจากการแจก ----------
update public.ins_staff
   set takes_new = false
 where emp_id in ('11001032', '11001246');

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--
--   -- ก) ใครรับใบใหม่อยู่บ้าง
--   select emp_id, split_part(note, ' · ', 1) as ชื่อ, active, role, takes_new
--     from public.ins_staff where role = 'agent' order by takes_new desc, emp_id;
--   -- 11001032 กับ 11001246 ต้องได้ takes_new = false · คนอื่น true
--
--   -- ข) ใบที่ 2 คนนี้ถืออยู่ (ยังไม่ปิด/ไม่ยกเลิก) — ถ้าอยากย้ายให้คนอื่น ใช้ปุ่มเปลี่ยนผู้ดูแลในหน้าเว็บ
--   select assigned_to, count(*) as ใบค้าง
--     from public.ins_requests
--    where assigned_to in ('11001032','11001246') and status not in ('done','cancelled')
--    group by assigned_to;
-- ============================================================================
