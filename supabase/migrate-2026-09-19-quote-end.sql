-- ============================================================================
-- วันสิ้นสุดความคุ้มครอง ประกันภัย (ภาคสมัครใจ) + พ.ร.บ. (2026-09-19)
--   เพิ่มจากไฟล์ migrate-2026-09-19-quote-dates.sql (วันเริ่ม) — เจ้าหน้าที่เลือกวันสิ้นสุดเองได้
--   (หน้าเว็บเติมให้ = วันเริ่ม + 1 ปี แต่แก้ได้)
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent) · มีคอลัมน์วันเริ่มในไฟล์นี้ด้วย (เผื่อยังไม่ได้รันไฟล์ก่อนหน้า)
-- ⚠️ ต้องรันหลัง migrate-2026-09-16-quote.sql และ migrate-2026-09-18-car-reg.sql (วิวด้านล่างมีคอลัมน์ของทั้งสองไฟล์)
-- 🔑 ins_set_quote เพิ่มพารามิเตอร์อีก 2 ตัว → ลบ "ตัวเก่าทั้งสองรุ่น" ก่อน
--    (ถ้าค้างไว้หลายตัว PostgREST เลือกไม่ถูกว่าจะเรียกตัวไหน แล้วบันทึกเบี้ยไม่ได้เลย)
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ใหม่ ----------
alter table public.ins_requests
  add column if not exists quote_start     date,     -- วันเริ่มคุ้มครอง ประกันภัย (ภาคสมัครใจ)
  add column if not exists quote_act_start date,     -- วันเริ่มคุ้มครอง พ.ร.บ.
  add column if not exists quote_end       date,     -- วันสิ้นสุด ประกันภัย
  add column if not exists quote_act_end   date;     -- วันสิ้นสุด พ.ร.บ.

-- ---------- 2) วิวสำหรับหน้าเจ้าหน้าที่ ----------
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
         car_province, car_vin,
         quote_start, quote_act_start,
         quote_end, quote_act_end
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;

-- ---------- 3) ins_set_quote รับวันเริ่ม + วันสิ้นสุด ----------
drop function if exists public.ins_set_quote(uuid, text, text, numeric, numeric, numeric,
                                             numeric, numeric, numeric, text);
drop function if exists public.ins_set_quote(uuid, text, text, numeric, numeric, numeric,
                                             numeric, numeric, numeric, text, date, date);

create or replace function public.ins_set_quote(
  p_req       uuid,
  p_insurer   text    default null,
  p_type      text    default null,
  p_net       numeric default null,
  p_gross     numeric default null,
  p_disc      numeric default null,
  p_act_net   numeric default null,
  p_act_gross numeric default null,
  p_act_disc  numeric default null,
  p_note      text    default null,
  p_start     date    default null,
  p_act_start date    default null,
  p_end       date    default null,
  p_act_end   date    default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_max   numeric := 9999999.99;                       -- เพดานต่อช่อง (เบี้ยรถไม่มีทางถึง 10 ล้าน)
  v_ins   text := nullif(btrim(coalesce(p_insurer, '')), '');
  v_typ   text := nullif(btrim(coalesce(p_type,    '')), '');
  v_note  text := left(coalesce(nullif(btrim(coalesce(p_note, '')), ''), ''), 300);
  v_net   numeric := public.ins_r2(p_net);
  v_gr    numeric := public.ins_r2(p_gross);
  v_dc    numeric := public.ins_r2(p_disc);
  v_anet  numeric := public.ins_r2(p_act_net);
  v_agr   numeric := public.ins_r2(p_act_gross);
  v_adc   numeric := public.ins_r2(p_act_disc);
  v_sum1  numeric;
  v_sum2  numeric;
  v_total numeric;
  v_empty boolean;
  v_status     text;
  v_new_status text;
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;

  -- ตัวเลขต้องไม่ติดลบและไม่เกินเพดาน
  if v_net  < 0 or v_gr   < 0 or v_dc  < 0
  or v_anet < 0 or v_agr  < 0 or v_adc < 0 then
    raise exception 'จำนวนเงินติดลบไม่ได้' using errcode = 'P0001';
  end if;
  if v_net  > c_max or v_gr  > c_max or v_dc  > c_max
  or v_anet > c_max or v_agr > c_max or v_adc > c_max then
    raise exception 'จำนวนเงินเกินที่ระบบรับได้ (สูงสุด 9,999,999.99 บาทต่อช่อง)' using errcode = 'P0001';
  end if;

  -- เบี้ยสุทธิ = ก่อนภาษี/อากร จึงต้องไม่มากกว่าเบี้ยรวม (ดักกรอกสลับช่อง)
  if v_net is not null and v_gr is not null and v_net > v_gr then
    raise exception 'เบี้ยสุทธิมากกว่าเบี้ยรวม — กรอกสลับช่องหรือไม่' using errcode = 'P0001';
  end if;
  if v_anet is not null and v_agr is not null and v_anet > v_agr then
    raise exception 'เบี้ยสุทธิ พ.ร.บ. มากกว่าเบี้ยรวม พ.ร.บ.' using errcode = 'P0001';
  end if;

  -- ส่วนลดต้องไม่มากกว่าเบี้ยรวม (ไม่งั้นยอดที่ต้องชำระติดลบ)
  if coalesce(v_dc, 0) > coalesce(v_gr, 0) then
    raise exception 'ส่วนลดมากกว่าเบี้ยรวม' using errcode = 'P0001';
  end if;
  if coalesce(v_adc, 0) > coalesce(v_agr, 0) then
    raise exception 'ส่วนลด พ.ร.บ. มากกว่าเบี้ยรวม พ.ร.บ.' using errcode = 'P0001';
  end if;

  -- วันเริ่มคุ้มครองต้องเป็นปีที่สมเหตุสมผล (กันพิมพ์ปี พ.ศ. ลงช่อง ค.ศ. เช่น 2569 → ค.ศ. 2569)
  if (p_start is not null and (p_start < date '2000-01-01' or p_start > date '2100-12-31'))
  or (p_act_start is not null and (p_act_start < date '2000-01-01' or p_act_start > date '2100-12-31')) then
    raise exception 'วันเริ่มคุ้มครองไม่ถูกต้อง' using errcode = 'P0001';
  end if;
  if (p_end is not null and (p_end < date '2000-01-01' or p_end > date '2101-12-31'))
  or (p_act_end is not null and (p_act_end < date '2000-01-01' or p_act_end > date '2101-12-31')) then
    raise exception 'วันสิ้นสุดความคุ้มครองไม่ถูกต้อง' using errcode = 'P0001';
  end if;
  -- วันสิ้นสุดต้องหลังวันเริ่ม (ดักเลือกสลับกัน)
  if (p_start is not null and p_end is not null and p_end <= p_start) then
    raise exception 'วันสิ้นสุดความคุ้มครอง (ประกันภัย) ต้องหลังวันเริ่ม' using errcode = 'P0001';
  end if;
  if (p_act_start is not null and p_act_end is not null and p_act_end <= p_act_start) then
    raise exception 'วันสิ้นสุดความคุ้มครอง พ.ร.บ. ต้องหลังวันเริ่ม' using errcode = 'P0001';
  end if;

  v_sum1  := coalesce(v_gr,  0) - coalesce(v_dc,  0);
  v_sum2  := coalesce(v_agr, 0) - coalesce(v_adc, 0);
  v_total := v_sum1 + v_sum2;

  v_empty := v_ins is null and v_typ is null and v_note = ''
             and v_net is null and v_gr is null and v_dc is null
             and v_anet is null and v_agr is null and v_adc is null
             and p_start is null and p_act_start is null
             and p_end is null and p_act_end is null;

  select status into v_status
    from public.ins_requests
   where id = p_req and public.ins_can_see(assigned_to);
  if not found then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;

  -- กรอกเบี้ยแล้ว = เสนอราคาแล้ว → เลื่อนสถานะให้เอง (เฉพาะใบที่ยังไม่ถึงขั้นนั้น)
  -- ไม่ถอยสถานะที่ปิดไปแล้ว (done/cancelled) และไม่ถอย quoted กลับ
  if not v_empty and v_total > 0 and v_status in ('new', 'contacted') then
    v_new_status := 'quoted';
  end if;

  update public.ins_requests
     set quote_insurer   = case when v_empty then null else v_ins end,
         quote_type      = case when v_empty then null else v_typ end,
         quote_net       = case when v_empty then null else v_net end,
         quote_gross     = case when v_empty then null else v_gr  end,
         quote_disc      = case when v_empty then null else v_dc  end,
         quote_act_net   = case when v_empty then null else v_anet end,
         quote_act_gross = case when v_empty then null else v_agr  end,
         quote_act_disc  = case when v_empty then null else v_adc  end,
         quote_total     = case when v_empty then null else v_total end,
         quote_note      = case when v_empty or v_note = '' then null else v_note end,
         quote_start     = case when v_empty then null else p_start end,
         quote_act_start = case when v_empty then null else p_act_start end,
         quote_end       = case when v_empty then null else p_end end,
         quote_act_end   = case when v_empty then null else p_act_end end,
         quote_at        = case when v_empty then null else now() end,
         quote_by        = case when v_empty then null else public.ins_my_emp() end,
         status          = coalesce(v_new_status, status),
         updated_at      = now()
   where id = p_req and public.ins_can_see(assigned_to);

  return jsonb_build_object(
           'ok',        true,
           'cleared',   v_empty,
           'total',     case when v_empty then null else v_total end,
           'sumMain',   case when v_empty then null else v_sum1 end,
           'sumAct',    case when v_empty then null else v_sum2 end,
           'status',    coalesce(v_new_status, v_status),
           'statusChanged', v_new_status is not null,
           'quoteBy',   case when v_empty then null else public.ins_my_emp() end);
end;
$$;

revoke all on function public.ins_set_quote(uuid, text, text, numeric, numeric, numeric,
                                            numeric, numeric, numeric, text, date, date, date, date) from public;
grant execute on function public.ins_set_quote(uuid, text, text, numeric, numeric, numeric,
                                               numeric, numeric, numeric, text, date, date, date, date) to authenticated;

commit;

-- ให้ API เห็นฟังก์ชัน/คอลัมน์ใหม่ทันที (ปกติ Supabase โหลดใหม่เอง — สั่งซ้ำไม่มีผลเสีย)
notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select (select count(*) from information_schema.columns
--            where table_name='ins_requests_view' and column_name in ('quote_start','quote_act_start','quote_end','quote_act_end')) as view_cols,
--          (select count(*) from pg_proc where proname='ins_set_quote') as fn_count;
--   -- ต้องได้ view_cols = 4 · fn_count = 1
-- ============================================================================
