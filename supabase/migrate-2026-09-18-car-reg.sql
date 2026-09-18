-- ============================================================================
-- อ่านสำเนาทะเบียนรถ (2026-09-18)
--   ฟอร์มลูกค้าอ่าน "เลขทะเบียน · จังหวัด · เลขตัวรถ" จากรูปสำเนาทะเบียนรถด้วย OCR ในเครื่องผู้กรอก
--   ผู้กรอกตรวจ/แก้แล้วส่งมากับคำขอ
--
--   • เลขทะเบียน → คอลัมน์เดิม car_plate (ins_submit รับ payload.carPlate อยู่แล้ว ไม่ต้องแก้)
--   • จังหวัด    → คอลัมน์ใหม่ car_province
--   • เลขตัวรถ   → คอลัมน์ใหม่ car_vin
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- 🔑 ไม่เขียน ins_submit ใหม่ทั้งตัว — "แทนข้อความ 2 จุด" ในตัวที่อยู่บน prod ตอนนี้
--    (แพตเทิร์นเดียวกับ migrate-2026-09-15-seq-1000.sql) กันไปทับของที่แก้ไว้หลังไฟล์ migrate ฉบับเต็ม
--    ถ้าหาจุดที่จะแทนไม่เจอ/เจอเกิน 1 จุด → หยุดทั้งไฟล์ ไม่แก้ครึ่ง ๆ
-- ⚠️ ต้องรันหลัง migrate-2026-09-16-quote.sql (วิวด้านล่างมีคอลัมน์ quote_* ด้วย)
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ใหม่ ----------
alter table public.ins_requests
  add column if not exists car_province text,      -- จังหวัดบนป้ายทะเบียน
  add column if not exists car_vin      text;      -- เลขตัวรถ (VIN / เลขตัวถัง)

-- ---------- 2) ให้ ins_submit เก็บ 2 ช่องใหม่ ----------
do $f$
declare
  d   text;
  c1  text := 'birth_date, insured_title';
  c1n text := 'birth_date, insured_title, car_province, car_vin';
  v1  text := 'v_birth, v_title';
  v1n text := 'v_birth, v_title, '
           || 'left(btrim(coalesce(payload->>''carProvince'', '''')), 60), '
           || 'nullif(left(upper(regexp_replace(coalesce(payload->>''carVin'', ''''), ''[^0-9A-Za-z]'', '''', ''g'')), 25), '''')';
  n   int;
begin
  d := pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure);
  if position('car_vin' in d) > 0 then
    raise notice 'ins_submit เก็บ car_vin อยู่แล้ว — ข้าม';
  else
    n := (length(d) - length(replace(d, c1, ''))) / length(c1);
    if n <> 1 then raise exception 'ins_submit: หา "%" เจอ % จุด (ต้อง 1)', c1, n; end if;
    n := (length(d) - length(replace(d, v1, ''))) / length(v1);
    if n <> 1 then raise exception 'ins_submit: หา "%" เจอ % จุด (ต้อง 1)', v1, n; end if;
    d := replace(d, c1, c1n);
    d := replace(d, v1, v1n);
    execute d;                              -- create or replace → สิทธิ์ (grant) เดิมยังอยู่ครบ
  end if;
end $f$;

-- ---------- 3) วิวสำหรับหน้าเจ้าหน้าที่ ----------
-- 🔑 เขียนคอลัมน์ให้ครบทุกตัว (create or replace view แทนทั้งก้อน) และ "ห้ามมี upload_token"
create or replace view public.ins_requests_view
with (security_invoker = true) as
  select id, no, kind,
         emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
         insured_name, addr, moo, road, tambon, amphoe, province,
         phone_home, phone_mobile, relation, relation_note,
         car_brand, car_model, car_plate, car_year, covers,
         doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note,
         note, status, status_note, created_at, updated_at,
         assigned_to, assigned_at,
         id_card, zipcode, occupation, workplace, income,
         consent_at, consent_version, birth_date,
         insured_title,
         quote_insurer, quote_type,
         quote_net, quote_gross, quote_disc,
         quote_act_net, quote_act_gross, quote_act_disc,
         quote_total, quote_note, quote_at, quote_by,
         car_province, car_vin
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;

commit;

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select position('car_vin' in pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure)) > 0 as submit_ok,
--          (select count(*) from information_schema.columns
--            where table_name='ins_requests_view' and column_name in ('car_province','car_vin')) as view_cols;
--   -- ต้องได้ submit_ok = true · view_cols = 2
-- ============================================================================
