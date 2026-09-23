-- ============================================================================
-- เก็บ "สาขา" ไว้ในทำเนียบพนักงาน — 2026-09-23
--
-- เดิม: สาขามาจากดรอปดาวน์ในฟอร์มล้วน ๆ (ฝั่งหน้าเว็บเดาจากหลักแรกของรหัสให้)
--       → ผู้กรอกเปลี่ยนเองได้ และฝั่งเซิร์ฟเวอร์ไม่มีข้อมูลไว้ตรวจสอบเลย
-- ใหม่: employees.branch เป็นแหล่งจริง · ins_submit ใช้สาขาจากทำเนียบทับที่ส่งมา
--       (กติกาเดียวกับชื่อและแผนกที่ทำไว้แล้ว — ทำเนียบชนะเสมอถ้าเจอรหัส)
--
-- ⚠️ ต้องรันไฟล์ employees-2026-09-23.sql (ที่มีคอลัมน์สาขา) หลังไฟล์นี้
--    ไม่งั้น branch จะยังว่าง แล้วระบบจะตกไปใช้ค่าจากฟอร์มเหมือนเดิม (ไม่พัง)
--
-- ปลอดภัยต่อการรันซ้ำ · ไม่ลบข้อมูล
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ใหม่ ----------
alter table public.employees add column if not exists branch text not null default '';

-- ---------- 2) ค้นรหัสพนักงาน: คืนสาขามาด้วย ----------
--   เปลี่ยนชนิดที่คืน → ต้อง drop ก่อน (create or replace เปลี่ยนคอลัมน์ผลลัพธ์ไม่ได้)
--   🔑 drop แล้วต้อง grant ใหม่ ไม่งั้นฟอร์มสาธารณะเรียกไม่ได้ = กรอกรหัสแล้วไม่ขึ้นชื่อ
drop function if exists public.ins_lookup_emp(text, text);
create or replace function public.ins_lookup_emp(p_emp_id text, p_brand text default 'toyota')
returns table (found boolean, name text, dept text, branch text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_br text := public.ins_brand(p_brand);
  r    record;
begin
  -- ฮีโน่มีพนักงานรหัสสั้น (เช่น '1') จึงผ่อนเป็นอย่างน้อย 1 ตัว แต่ยังคืนแค่ทีละคน
  if length(v_id) < 1 then
    return query select false, ''::text, ''::text, ''::text;
    return;
  end if;
  select e.name, e.dept, e.branch into r from public.employees e
   where e.emp_id = v_id and e.brand = v_br and e.active is true;
  if not found then
    return query select false, ''::text, ''::text, ''::text;
  else
    return query select true, r.name, r.dept, coalesce(r.branch, '');
  end if;
end;
$$;

revoke all on function public.ins_lookup_emp(text, text) from public;
grant execute on function public.ins_lookup_emp(text, text) to anon, authenticated;

-- ---------- 3) ins_submit: สาขาจากทำเนียบชนะค่าที่ฟอร์มส่งมา ----------
--   ไม่เขียนฟังก์ชันใหม่ทั้งตัว — แทนข้อความในตัวที่อยู่บน prod ตอนนี้
--   หาจุดไม่เจอ/เจอหลายที่ = ยกเลิกทั้งไฟล์ ดีกว่าแก้ครึ่ง ๆ
do $f$
declare
  d   text := pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure);
  a   text := 'left(coalesce(payload->>''empBranch'', ''''), 60)';
  an  text := 'coalesce(nullif((select e2.branch from public.employees e2'
              || ' where e2.emp_id = v_emp_id and e2.brand = v_brand and e2.active is true), ''''),'
              || ' left(coalesce(payload->>''empBranch'', ''''), 60))';
  n   int;
begin
  if position('e2.branch' in d) > 0 then
    raise notice 'ins_submit: ใช้สาขาจากทำเนียบอยู่แล้ว — ข้าม';
    return;
  end if;
  n := (length(d) - length(replace(d, a, ''))) / length(a);
  if n <> 1 then
    raise exception 'ins_submit: หาจุดใส่สาขาไม่เจอ หรือเจอ % ที่ (ต้องเจอ 1 ที่)', n;
  end if;
  execute replace(d, a, an);
end $f$;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยก)
--
--   select (select count(*) from information_schema.columns
--            where table_name = 'employees' and column_name = 'branch')          as มีคอลัมน์สาขา,
--          (select count(*) from information_schema.routines
--            where routine_name = 'ins_lookup_emp')                              as มีฟังก์ชันค้นรหัส,
--          (select position('e2.branch' in
--             pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure)) > 0) as submit_ใช้สาขาทำเนียบ;
--
--   -- หลังรันไฟล์รายชื่อแล้ว ลองค้นดูสัก 3 รหัส (คนละสาขา)
--   select * from public.ins_lookup_emp('11001001', 'toyota');   -- สำนักงานใหญ่
--   select * from public.ins_lookup_emp('21001007', 'toyota');   -- ท่ามะกา
--   select * from public.ins_lookup_emp('31001003', 'toyota');   -- พนมทวน
--
--   -- สรุปจำนวนคนต่อสาขา
--   select branch, count(*) from public.employees
--    where brand = 'toyota' and active group by 1 order by 1;
-- ============================================================================
