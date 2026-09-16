-- ============================================================================
-- ข้อมูลเสนอราคาของเจ้าหน้าที่ประกัน (2026-09-16)
--   บริษัทประกัน · ประเภทประกัน · เบี้ยสุทธิ / เบี้ยรวม / ส่วนลด
--   แยก 2 ก้อนตามฟอร์มกระดาษ: "ประเภท" กับ "พ.ร.บ." แล้วรวมเป็น "รวมทั้งสิ้น"
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ✅ ไม่แตะ ins_submit / ไม่แตะคอลัมน์เดิม — เพิ่มคอลัมน์ใหม่ + วิวใหม่ + RPC ใหม่เท่านั้น
--    (ฟอร์มฝั่งลูกค้าไม่เกี่ยวเลย ช่องพวกนี้เจ้าหน้าที่กรอกในหน้า staff.html)
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ใหม่ ----------
alter table public.ins_requests
  add column if not exists quote_insurer   text,                   -- ชื่อบริษัทประกัน (ชื่อเต็มตามที่ฝ่ายประกันใช้ใน Excel)
  add column if not exists quote_type      text,                   -- ประเภทประกัน เช่น 'ประกันภัยประเภท 2 พลัส'
  add column if not exists quote_net       numeric(12,2),          -- เบี้ยสุทธิ (ประเภท)
  add column if not exists quote_gross     numeric(12,2),          -- เบี้ยรวม  (ประเภท)
  add column if not exists quote_disc      numeric(12,2),          -- ส่วนลด    (ประเภท)
  add column if not exists quote_act_net   numeric(12,2),          -- เบี้ยสุทธิ พ.ร.บ.
  add column if not exists quote_act_gross numeric(12,2),          -- เบี้ยรวม  พ.ร.บ.
  add column if not exists quote_act_disc  numeric(12,2),          -- ส่วนลด    พ.ร.บ.
  add column if not exists quote_total     numeric(12,2),          -- รวมทั้งสิ้น (คำนวณในเซิร์ฟเวอร์ ไม่เชื่อค่าจากหน้าเว็บ)
  add column if not exists quote_note      text,
  add column if not exists quote_at        timestamptz,
  add column if not exists quote_by        text;                   -- รหัสพนักงานที่กรอก

comment on column public.ins_requests.quote_total is
  'รวมทั้งสิ้น = (เบี้ยรวมประเภท − ส่วนลด) + (เบี้ยรวม พ.ร.บ. − ส่วนลด) — คำนวณโดย ins_set_quote() เท่านั้น';

-- ค้นหาใบที่เสนอราคาแล้วได้เร็ว (ใช้ตอนทำรายงาน/ตามงาน)
create index if not exists ins_requests_quote_at_idx
  on public.ins_requests (quote_at desc) where quote_at is not null;

-- ---------- 2) วิวสำหรับหน้าเจ้าหน้าที่ ----------
-- 🔑 ต้องเขียนคอลัมน์ให้ครบทุกตัว เพราะ create or replace view แทนทั้งก้อน
--    และ "ห้ามมี upload_token" (Postgres ไม่มี RLS ระดับคอลัมน์ — select ตารางตรงกุญแจแนบไฟล์จะหลุด)
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
         quote_total, quote_note, quote_at, quote_by
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;

-- ---------- 3) ตัวช่วยปัดเศษ ----------
-- ปัด 2 ตำแหน่งทีละช่อง (กติกาเดิมของระบบ: ปัดรายบรรทัด ไม่ปัดยอดรวมแล้วเฉลี่ยกลับ)
create or replace function public.ins_r2(p numeric)
returns numeric
language sql
immutable
as $$ select case when p is null then null else round(p, 2) end $$;

-- ---------- 4) บันทึกข้อมูลเสนอราคา ----------
-- security definer: ข้าม RLS แล้วเช็คสิทธิ์เอง (แพตเทิร์นเดียวกับ ins_set_status)
--   • ต้องเป็นเจ้าหน้าที่ประกัน (is_ins_staff)
--   • ต้องเป็นใบที่ตัวเองดูแล หรือเป็นบัญชีที่เห็นทุกใบ (ins_can_see)
--   • ส่งค่าว่างมาทั้งหมด = ล้างข้อมูลเสนอราคาของใบนั้น
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
  p_note      text    default null)
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

  v_sum1  := coalesce(v_gr,  0) - coalesce(v_dc,  0);
  v_sum2  := coalesce(v_agr, 0) - coalesce(v_adc, 0);
  v_total := v_sum1 + v_sum2;

  v_empty := v_ins is null and v_typ is null and v_note = ''
             and v_net is null and v_gr is null and v_dc is null
             and v_anet is null and v_agr is null and v_adc is null;

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

revoke all on function public.ins_r2(numeric) from public;
revoke all on function public.ins_set_quote(uuid, text, text, numeric, numeric, numeric,
                                            numeric, numeric, numeric, text) from public;
grant execute on function public.ins_set_quote(uuid, text, text, numeric, numeric, numeric,
                                               numeric, numeric, numeric, text) to authenticated;

commit;

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select column_name from information_schema.columns
--    where table_name='ins_requests_view' and column_name like 'quote%' order by 1;
--   -- ต้องได้ 12 แถว
-- ============================================================================
