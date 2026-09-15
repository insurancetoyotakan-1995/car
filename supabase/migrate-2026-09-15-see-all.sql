-- =====================================================================
--  migrate 2026-09-15 (6) : เจ้าหน้าที่ที่ "เห็นทุกใบ + รับงานด้วย" (ins_staff.see_all)
--
--  role = 'admin'            → เห็นทุกใบ แต่ไม่รับงาน/ไม่อยู่ในแผงภาระงาน (บัญชีกลาง)
--  role = 'agent'            → รับงาน เห็นเฉพาะใบตัวเอง
--  role = 'agent' + see_all  → รับงาน + อยู่ในแผงภาระงาน + เห็นทุกใบ/เปลี่ยนผู้ดูแลได้ + LINE สรุปทุกใบใหม่
--
--  แก้ 3 ฟังก์ชันที่มีอยู่แบบ "แทนข้อความใน definition ปัจจุบัน" (ไม่ต้องคัดลอกทั้งฟังก์ชัน)
--    is_ins_admin()    s.role = 'admin'           → (s.role = 'admin' or s.see_all)
--    ins_whoami()      'role', s.role             → see_all ส่ง 'admin' ให้หน้าเว็บเปิดโหมดผู้ดูแล
--    ins_notify_trg()  active and role = 'admin'  → (role = 'admin' or see_all)
--  รันซ้ำได้ (ข้ามฟังก์ชันที่แก้แล้ว) · เจอข้อความไม่ครบ 1 จุด = หยุด ไม่แก้มั่ว
--
--  ✅ รันบน prod แล้ว 2026-09-15 · 11001246 กุลธิภัสร์ = agent + see_all
--  ⚠️ migrate ใหม่ที่ redefine 3 ฟังก์ชันนี้ต้องคงเงื่อนไข see_all ไว้
-- =====================================================================

alter table public.ins_staff add column if not exists see_all boolean not null default false;

do $p$
declare d text; n int;
begin
  d := pg_get_functiondef('public.is_ins_admin()'::regprocedure);
  if position('see_all' in d) = 0 then
    n := (length(d) - length(replace(d, 's.role = ''admin''', ''))) / length('s.role = ''admin''');
    if n <> 1 then raise exception 'is_ins_admin: found % places', n; end if;
    execute replace(d, 's.role = ''admin''', '(s.role = ''admin'' or s.see_all)');
  end if;

  d := pg_get_functiondef('public.ins_whoami()'::regprocedure);
  if position('see_all' in d) = 0 then
    n := (length(d) - length(replace(d, 's.role,', ''))) / length('s.role,');
    if n <> 1 then raise exception 'ins_whoami: found % places', n; end if;
    execute replace(d, 's.role,', 'case when s.see_all then ''admin'' else s.role end,');
  end if;

  d := pg_get_functiondef('public.ins_notify_trg()'::regprocedure);
  if position('see_all' in d) = 0 then
    n := (length(d) - length(replace(d, 'active and role = ''admin''', ''))) / length('active and role = ''admin''');
    if n <> 1 then raise exception 'ins_notify_trg: found % places', n; end if;
    execute replace(d, 'active and role = ''admin''', 'active and (role = ''admin'' or see_all)');
  end if;
end $p$;

update public.ins_staff set role = 'agent', see_all = true where emp_id = '11001246';
