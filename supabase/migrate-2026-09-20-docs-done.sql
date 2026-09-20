-- ============================================================================
-- 2 เรื่องในไฟล์เดียว (2026-09-20)
--   1) ฝ่ายบุคคล (ins_viewers) อ่านกรมธรรม์ที่ยังไม่หมดอายุได้ → เห็นแถบ "รถคันที่ 2" ครบเหมือนเจ้าหน้าที่
--   2) บังคับ "เอกสารครบ" ก่อนปิดการขาย — ตรวจที่ฐานข้อมูล ไม่ใช่แค่หน้าเว็บ
--      เอกสารบังคับ = สำเนาทะเบียนรถ (carReg) · สำเนาบัตรประชาชน (idCard) · สำเนากรมธรรม์เดิม (oldPolicy)
--      🔑 ฟอร์มลูกค้าบังคับแนบอยู่แล้ว แต่ไฟล์อัปโหลด "หลัง" บันทึกใบคำขอ (ปิดเบราว์เซอร์กลางคัน = ใบไม่มีไฟล์)
--         ด่านนี้จึงดักตอนปิดการขาย ซึ่งเป็นจุดที่เอกสารต้องครบจริง ๆ
--      ⚠️ บัญชีกลาง/ผู้ดูแล (is_ins_admin) ปิดการขายได้แม้เอกสารไม่ครบ — เผื่อใบเก่าหรือเคสที่ลูกค้าส่งเอกสารทางอื่น
--         (ใบเก่าที่ยัง "ปิดการขาย" ไปแล้วไม่ถูกแตะ ไฟล์นี้ตรวจเฉพาะตอนเปลี่ยนสถานะครั้งใหม่)
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-19-viewer.sql
-- ============================================================================

begin;

-- ---------- 1) ฝ่ายบุคคลอ่านกรมธรรม์ที่ยังมีผลได้ ----------
create or replace function public.ins_active_policies()
returns table (emp_id text, plate text, vin text, expire_on date)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_ins_staff() or public.ins_is_viewer()) then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกันและบัญชีดูอย่างเดียว)' using errcode = 'P0001';
  end if;
  return query
    select a.emp_id, a.plate, a.vin, a.expire_on
      from public.ins_active_policy a
     where a.expire_on >= public.ins_today()
     order by a.emp_id, a.expire_on;
end;
$$;

-- ---------- 2) เอกสารที่ยังขาด ----------
--   คืนชื่อเอกสารที่ยังไม่มีไฟล์แนบ (ว่าง = ครบ) · ใช้ทั้งในด่านปิดการขายและให้หน้าเว็บถามล่วงหน้า
create or replace function public.ins_missing_docs(p_req uuid)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(d.label order by d.ord), '{}')
    from (values ('carReg', 'สำเนาทะเบียนรถ', 1),
                 ('idCard', 'สำเนาบัตรประชาชนผู้ทำประกัน', 2),
                 ('oldPolicy', 'สำเนากรมธรรม์เดิม', 3)) as d(tag, label, ord)
   where not exists (select 1 from public.ins_files f where f.req_id = p_req and f.tag = d.tag);
$$;

-- หน้าเว็บถามได้ (เฉพาะใบที่บัญชีนั้นเห็น) → บอกเจ้าหน้าที่ล่วงหน้าว่าขาดอะไร
create or replace function public.ins_req_docs(p_req uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.ins_requests r where r.id = p_req and public.ins_can_see(r.assigned_to)) then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;
  return public.ins_missing_docs(p_req);
end;
$$;

-- ---------- 3) ด่านตอนปิดการขาย ----------
create or replace function public.ins_set_status(p_req uuid, p_status text, p_note text)
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
     set status = p_status, status_note = left(coalesce(p_note,''), 300), updated_at = now()
   where id = p_req and public.ins_can_see(assigned_to);
  if not found then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- 4) สิทธิ์ ----------
revoke all on function public.ins_missing_docs(uuid) from public, anon, authenticated;
revoke all on function public.ins_req_docs(uuid)     from public, anon;
grant execute on function public.ins_req_docs(uuid)  to authenticated;
revoke all on function public.ins_active_policies()  from public, anon;
grant execute on function public.ins_active_policies() to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select (select count(*) from pg_proc where proname = 'ins_missing_docs') as miss_fn,
--          (select count(*) from pg_proc where proname = 'ins_req_docs')     as docs_fn,
--          (select count(*) from pg_proc where proname = 'ins_set_status')   as status_fn,
--          (select count(*) from pg_proc where proname = 'ins_active_policies') as pol_fn;
--   -- ต้องได้ 1 ทุกช่อง
-- ============================================================================
