-- ============================================================================
-- เลขที่ใบเสร็จ (2026-09-21)
--
--   ผู้ใช้สั่ง: ให้คีย์เลขที่ใบเสร็จได้ในหน้าเจ้าหน้าที่ และพิมพ์ติดไปบนใบค่าคอม
--   (อยู่ใต้ "เลขที่คำขอ" บนหัวเอกสาร)
--
--   เก็บรวมกับการบันทึกสถานะ เพราะเลขใบเสร็จออกตอนปิดการขาย = จังหวะเดียวกัน
--   🔑 p_receipt = null → "ไม่แตะของเดิม" (หน้าเว็บรุ่นเก่าที่ยังส่ง 3 พารามิเตอร์จะไม่ล้างค่าทิ้ง)
--      ส่งค่าว่าง '' มา = ตั้งใจล้าง
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-21-brand.sql
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ใหม่ ----------
alter table public.ins_requests
  add column if not exists receipt_no text not null default '';

comment on column public.ins_requests.receipt_no is
  'เลขที่ใบเสร็จ — เจ้าหน้าที่คีย์ตอนปิดการขาย · แสดงบนใบสรุปค่าคอมมิชชั่น/ค่าแนะนำลูกค้า';

-- ---------- 2) บันทึกสถานะ: รับเลขใบเสร็จมาด้วย ----------
--   ตัวเก่า (3 พารามิเตอร์) ต้องทิ้ง ไม่งั้นเรียกด้วย 3 อาร์กิวเมนต์แล้ว Postgres เลือกไม่ถูก
drop function if exists public.ins_set_status(uuid, text, text);
create or replace function public.ins_set_status(p_req uuid, p_status text, p_note text,
                                                 p_receipt text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_miss text[];
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  if p_status not in ('new','contacted','quoted','done','cancelled') then
    raise exception 'สถานะไม่ถูกต้อง' using errcode = 'P0001';
  end if;

  -- ปิดการขาย = เอกสารต้องครบ (บัญชีกลางข้ามได้)
  if p_status = 'done' and not public.is_ins_admin() then
    v_miss := public.ins_missing_docs(p_req);
    if array_length(v_miss, 1) > 0 then
      raise exception 'ปิดการขายไม่ได้ — ยังไม่มีไฟล์ % (แนบไฟล์ก่อน หรือให้บัญชีกลางเป็นคนปิด)',
        array_to_string(v_miss, ' · ') using errcode = 'P0001';
    end if;
  end if;

  update public.ins_requests
     set status = p_status,
         status_note = left(coalesce(p_note,''), 300),
         receipt_no = case when p_receipt is null then receipt_no
                           else left(btrim(p_receipt), 40) end,
         updated_at = now()
   where id = p_req and public.ins_can_see(assigned_to);
  if not found then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.ins_set_status(uuid, text, text, text) from public, anon;
grant execute on function public.ins_set_status(uuid, text, text, text) to authenticated;

-- ---------- 3) วิวสำหรับหน้าเจ้าหน้าที่ ----------
--   เพิ่มต่อท้ายคอลัมน์สุดท้าย → create or replace ทำได้ ไม่ต้อง drop
create or replace view public.ins_requests_view
with (security_invoker = true) as
  select id, no, kind, brand,
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
         car_province, car_vin,
         quote_start, quote_act_start, quote_end, quote_act_end,
         add_reason,
         receipt_no
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select (select count(*) from information_schema.columns
--            where table_name = 'ins_requests' and column_name = 'receipt_no')      as col_ok,
--          (select count(*) from information_schema.columns
--            where table_name = 'ins_requests_view' and column_name = 'receipt_no') as view_ok,
--          (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--            where n.nspname = 'public' and p.proname = 'ins_set_status')           as fn_count;
--   -- ต้องได้ col_ok = 1 · view_ok = 1 · fn_count = 1 (ตัวเก่า 3 พารามิเตอร์ถูกทิ้งแล้ว)
-- ============================================================================
