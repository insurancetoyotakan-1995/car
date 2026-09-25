-- ============================================================================
-- 🐞 ins_submit: join ทำเนียบพนักงานต้องระบุแบรนด์ — 2026-09-23
--
-- อาการ: หน้า "ส่งคำขอสำเร็จ" การ์ด "เจ้าหน้าที่ประกันที่ดูแลคำขอนี้"
--        อาจขึ้น "ชื่อคนฮีโน่" แทนชื่อเจ้าหน้าที่ประกันโตโยต้า (เบอร์ถูก แต่ชื่อผิดคน)
--
-- เหตุ:  ตั้งแต่ migrate-2026-09-21-brand.sql ทำเนียบมีกุญแจ (brand, emp_id)
--        และรหัสพนักงาน 2 บริษัทซ้ำกันได้จริง (ฮีโน่ 29 จาก 47 คนชนกับโตโยต้า)
--        ท่อน v_contact ใน ins_submit ยัง join แบบ e.emp_id = s.emp_id เฉย ๆ
--        → ได้หลายแถว แล้ว select into หยิบมาแถวเดียวแบบไม่แน่นอน
--
-- ทำไมเพิ่งเจอ: ตอนแยกแบรนด์ยังไม่มีเจ้าหน้าที่คนไหนมีเบอร์ในระบบ
--        การ์ดนี้เลยไม่เคยแสดง บั๊กจึงไม่โผล่จนวันที่เริ่มกรอกเบอร์
--        (migrate-2026-09-21-brand.sql แก้ให้ ins_whoami · ins_agents ·
--         ins_viewer_agents · ins_line_bind_srv ไปแล้ว แต่ตก ins_submit)
--
-- ปลอดภัยต่อการรันซ้ำ · ไม่แตะข้อมูล แก้แค่นิยามฟังก์ชัน
-- ============================================================================

begin;

do $f$
declare
  d   text := pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure);
  a   text := 'employees e on e.emp_id = s.emp_id';
  an  text := 'employees e on e.emp_id = s.emp_id and e.brand = ''toyota''';
  n   int;
begin
  if position(a in d) = 0 then
    raise notice 'ins_submit: ไม่มี join ทำเนียบแบบเดิม — ข้าม';
    return;
  end if;
  if position('e.emp_id = s.emp_id and e.brand' in d) > 0 then
    raise notice 'ins_submit: ระบุแบรนด์ไว้แล้ว — ข้าม';
    return;
  end if;
  n := (length(d) - length(replace(d, a, ''))) / length(a);
  if n <> 1 then
    raise exception 'ins_submit: เจอ join ทำเนียบ % ที่ (ต้องเจอ 1 ที่)', n;
  end if;
  execute replace(d, a, an);
end $f$;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน — ต้องได้ true
--   select position('e.emp_id = s.emp_id and e.brand' in
--            pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure)) > 0 as แก้แล้ว;
--
-- เบอร์โทรเจ้าหน้าที่ (ข้อมูลส่วนบุคคล) อยู่ในไฟล์ ins-staff-phone.sql ซึ่ง gitignore ไว้
-- ============================================================================
