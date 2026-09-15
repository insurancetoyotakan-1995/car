-- =====================================================================
--  migrate 2026-09-15 (7) : เลขรันเกิน 999 ใบ/เดือน
--  🐞 lpad('1000', 3, '0') = '100' (lpad ตัดข้อความที่ยาวเกิน) → ใบที่ 1,000 ของเดือนได้เลขซ้ำกับใบที่ 100
--     แล้วชน unique ของ ins_requests.no → ยื่นไม่ผ่านทุกใบจนขึ้นเดือนใหม่ (พบตอน load test)
--  แก้: lpad(v_n::text, greatest(3, length(v_n::text)), '0') → 001…999, 1000, 1001 …
--  แทนข้อความใน ins_submit ปัจจุบัน · รันซ้ำได้
--  ✅ รันบน prod แล้ว 2026-09-15 · ทดสอบ rollback: 998, 999, 1000, 1001, 1002 และต้นเดือนยัง 001
--  (migrate-2026-09-15-emp-owner.sql แก้บรรทัดเดียวกันไว้แล้ว)
-- =====================================================================
do $f$
declare d text; old text := 'lpad(v_n::text, 3, ''0'')'; n int;
begin
  d := pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure);
  if position('greatest(3, length(v_n::text))' in d) = 0 then
    n := (length(d) - length(replace(d, old, ''))) / length(old);
    if n <> 1 then raise exception 'ins_submit lpad: found % places', n; end if;
    execute replace(d, old, 'lpad(v_n::text, greatest(3, length(v_n::text)), ''0'')');
  end if;
end $f$;
