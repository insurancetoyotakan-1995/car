-- ============================================================================
-- ยอดที่ลูกค้าต้องชำระ ปัดขึ้นเป็นบาทเต็ม — 2026-10-01 (ผู้ใช้สั่ง)
--
--   ปัดทีละก้อน (ภาคสมัครใจ / พ.ร.บ.) แล้วค่อยรวม → ก้อนย่อยบนใบบวกกันได้เท่ายอดรวมพอดี
--     เบี้ยรวม 25,335.46 − ส่วนลด 3,537.45 = 21,798.01 → 21,799
--     พ.ร.บ.     848.55 − ส่วนลด    78.90 =    769.65 →    770
--     รวมทั้งสิ้น                                       22,569
--   (ปัดแค่ยอดรวมจะได้ 22,568 ซึ่งไม่เท่ากับ 21,799 + 770 ที่พิมพ์อยู่บนใบเดียวกัน)
--
--   ไม่แตะ: เบี้ยสุทธิ / เบี้ยรวม / ส่วนลด (ตัวเลขของบริษัทประกัน)
--           ค่าคอม/ค่าแนะนำ (คิดจากเบี้ยสุทธิ ไม่เกี่ยวกับยอดชำระ)
--
--   หน้าเว็บ (staff.html · payCeil/payOf) ปัดแบบเดียวกันอยู่แล้ว ไฟล์นี้ทำให้ quote_total
--   ที่เก็บในฐานข้อมูลตรงกับหน้าจอ (รายงาน / Excel / ใบค่าคอม)
--
-- ปลอดภัยต่อการรันซ้ำ · หาจุดแก้ไม่เจอ = ยกเลิกทั้งไฟล์
-- ============================================================================

begin;

-- ---------- 1) ins_set_quote: ปัดยอดแต่ละก้อนขึ้นก่อนรวม ----------
--   แก้ทุก overload ที่มีสูตรนี้ (ฟังก์ชันนี้เคยเพิ่มพารามิเตอร์มา 2 รอบ)
do $f$
declare
  fn  oid;
  d   text;
  n1  int;
  n2  int;
  hit int := 0;
begin
  for fn in select p.oid from pg_proc p join pg_namespace s on s.oid = p.pronamespace
             where s.nspname = 'public' and p.proname = 'ins_set_quote' loop
    d := pg_get_functiondef(fn);
    if position('ceil(coalesce(v_gr' in d) > 0 then
      raise notice 'ins_set_quote(%): ปัดขึ้นอยู่แล้ว — ข้าม', fn::regprocedure;
      hit := hit + 1;
      continue;
    end if;
    n1 := (select count(*) from regexp_matches(d, 'v_sum1\s*:=\s*coalesce\(v_gr,\s*0\)\s*-\s*coalesce\(v_dc,\s*0\)\s*;', 'g'));
    n2 := (select count(*) from regexp_matches(d, 'v_sum2\s*:=\s*coalesce\(v_agr,\s*0\)\s*-\s*coalesce\(v_adc,\s*0\)\s*;', 'g'));
    if n1 <> 1 or n2 <> 1 then
      raise notice 'ins_set_quote(%): ไม่ใช่สูตรที่รู้จัก (เจอ %/% ที่) — ข้าม', fn::regprocedure, n1, n2;
      continue;
    end if;
    d := regexp_replace(d, 'v_sum1\s*:=\s*(coalesce\(v_gr,\s*0\)\s*-\s*coalesce\(v_dc,\s*0\))\s*;',
                           'v_sum1  := ceil(\1);   -- ยอดชำระปัดขึ้นเป็นบาทเต็ม (2026-10-01)');
    d := regexp_replace(d, 'v_sum2\s*:=\s*(coalesce\(v_agr,\s*0\)\s*-\s*coalesce\(v_adc,\s*0\))\s*;',
                           'v_sum2  := ceil(\1);');
    execute d;
    hit := hit + 1;
  end loop;
  if hit = 0 then
    raise exception 'ไม่พบ ins_set_quote ที่แก้ได้ — ยกเลิกทั้งไฟล์ (ส่งผลนี้ให้ผู้ดูแลระบบดู)';
  end if;
end $f$;

-- ---------- 2) ปรับยอดของใบที่ยังไม่ปิดการขาย ให้เป็นกติกาใหม่ ----------
--   🔒 ไม่แตะใบที่ "ปิดการขาย" แล้ว — อาจออกใบเสร็จตามยอดเดิมไปแล้ว ยอดในระบบต้องตรงกับใบเสร็จ
--      (ถ้าต้องการปรับใบที่ปิดแล้วด้วย ดูคำสั่งท้ายไฟล์ — ตรวจกับใบเสร็จก่อน)
update public.ins_requests
   set quote_total = ceil(coalesce(quote_gross, 0) - coalesce(quote_disc, 0))
                   + ceil(coalesce(quote_act_gross, 0) - coalesce(quote_act_disc, 0))
 where quote_total is not null
   and status not in ('done', 'cancelled')
   and quote_total <> ceil(coalesce(quote_gross, 0) - coalesce(quote_disc, 0))
                    + ceil(coalesce(quote_act_gross, 0) - coalesce(quote_act_disc, 0));

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยก)
--
-- A) ฟังก์ชันปัดขึ้นแล้ว (ต้องได้ true)
--   select bool_and(position('ceil(coalesce(v_gr' in pg_get_functiondef(p.oid)) > 0) as ปัดขึ้นแล้ว
--     from pg_proc p join pg_namespace s on s.oid = p.pronamespace
--    where s.nspname = 'public' and p.proname = 'ins_set_quote';
--
-- B) ใบที่ปิดการขายแล้วแต่ยอดยังมีทศนิยม (ไม่ได้ถูกปรับ — ตรวจกับใบเสร็จว่าเก็บเงินจริงเท่าไร)
--   select no, quote_total as ยอดเดิม,
--          ceil(coalesce(quote_gross,0) - coalesce(quote_disc,0))
--        + ceil(coalesce(quote_act_gross,0) - coalesce(quote_act_disc,0)) as ยอดตามกติกาใหม่,
--          receipt_no as เลขใบเสร็จ
--     from public.ins_requests
--    where status = 'done' and quote_total is not null and quote_total <> trunc(quote_total)
--    order by no;
--
-- C) ถ้าตรวจแล้วอยากปรับใบที่ปิดแล้วด้วย (เลือกเฉพาะเลขที่ที่ต้องการ)
--   update public.ins_requests
--      set quote_total = ceil(coalesce(quote_gross,0) - coalesce(quote_disc,0))
--                      + ceil(coalesce(quote_act_gross,0) - coalesce(quote_act_disc,0))
--    where no in ('INS-2609-002');
-- ============================================================================
