-- ============================================================================
-- ข้อความ LINE: บอกบริษัทให้เห็นตั้งแต่บรรทัดแรก (2026-09-21)
--
--   ปัญหาของแบบเดิม (migrate-2026-09-21-brand.sql)
--     • LINE แสดงตัวอย่างแจ้งเตือนจาก "ต้นข้อความ" → "· ฮีโน่" ที่ต่อท้ายหัวข้อมองไม่เห็นตอนเด้ง
--     • คำว่าฮีโน่ซ้ำ 2 ที่ (ท้ายหัวข้อ + ท้ายชื่อพนักงาน) รกเปล่า ๆ
--
--   แบบใหม่: ขึ้นต้นด้วย [โตโยต้า] / [ฮีโน่] เสมอ
--     🔑 ติดป้ายทั้ง 2 แบรนด์ ไม่ใช่แค่ฮีโน่ — ถ้าติดข้างเดียวคนอ่านต้องจำกฎว่า
--        "ไม่มีป้าย = โตโยต้า" ซึ่งพลาดง่ายเวลารีบ และแยกไม่ออกว่าข้อความเก่าหรือใหม่
--
--   ใช้ OA เดิมตัวเดียวทั้ง 2 บริษัท (ผู้ใช้เลือก) — ไม่ต้องผูก LINE ใหม่ ไม่ต้องมี token ใหม่
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ · ไม่ส่งข้อความออกตอนรัน (แก้แต่ตัวประกอบข้อความ)
-- ⚠️ ต้องรันหลัง migrate-2026-09-21-brand.sql
-- ============================================================================

begin;

create or replace function public.ins_line_text(p_req public.ins_requests, p_head text, p_with_agent boolean)
returns text
language plpgsql stable
security definer
set search_path = public
as $$
declare
  v_agent text;
  v_refer boolean := p_req.kind = 'refer';
  v_cars  integer := 0;
  v_br    text := public.ins_brand(p_req.brand);
  v_label text := case when v_br = 'hino' then 'ฮีโน่' else 'โตโยต้า' end;   -- plpgsql ใช้ตัวที่ประกาศก่อนหน้าได้
  v_why   text := case p_req.add_reason
                    when 'own2'   then 'ขอเพิ่มรถคันที่ 2 ชื่อตัวเอง'
                    when 'family' then 'รถครอบครัวเชื่อมโยง'
                    when 'renew'  then 'ต่ออายุรถคันเดิม'
                    else null end;
begin
  if p_with_agent then
    select coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id) into v_agent
      from public.ins_staff s
      left join public.employees e on e.emp_id = s.emp_id and e.brand = 'toyota'
     where s.emp_id = p_req.assigned_to;
  end if;
  if not v_refer and coalesce(p_req.emp_id, '') <> '' then
    v_cars := public.ins_car_others(p_req.emp_id, p_req.car_plate, p_req.car_vin, p_req.id, v_br);
  end if;
  -- บริษัทมาก่อนทุกอย่าง → เห็นในตัวอย่างแจ้งเตือนบนหน้าจอล็อกได้เลย
  return '[' || v_label || '] ' || p_head
    || E'\nเลขที่: ' || p_req.no
    || E'\nแบบคำขอ: ' || case when v_refer then 'แนะนำลูกค้าทั่วไป' else 'พนักงานทำประกันเอง' end
    || E'\n' || case when v_refer then 'ลูกค้า: ' else 'ผู้ทำประกัน: ' end || regexp_replace(p_req.insured_name, '\s+', ' ', 'g')
    || E'\nโทร: ' || coalesce(nullif(p_req.phone_mobile, ''), '-')
    || E'\n' || case when v_refer then 'ผู้แนะนำ: ' else 'พนักงาน: ' end
    || regexp_replace(p_req.emp_name, '\s+', ' ', 'g')
    || case when coalesce(p_req.emp_dept, '') <> '' then ' (' || p_req.emp_dept || ')' else '' end
    || case when p_req.emp_verified then '' else ' · รหัสยังไม่ยืนยัน' end
    || case when v_why is not null then E'\nเหตุผล: ' || v_why else '' end
    || case when v_cars > 0
            then E'\n⚠️ รถคันที่ ' || (v_cars + 1) || ' ของพนักงาน — สิทธิ์ส่วนลด 10% เงินสด/โอนเท่านั้น'
            else '' end
    || case when p_with_agent then E'\nผู้ดูแล: ' || coalesce(v_agent, 'ยังไม่มี') else '' end
    || E'\n\nเปิดดู: https://insurancetoyotakan-1995.github.io/car/staff.html?no=' || p_req.no;
end;
$$;
revoke all on function public.ins_line_text(public.ins_requests, text, boolean) from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ดูตัวอย่างข้อความจริงจากใบที่มีอยู่ — อ่านอย่างเดียว ไม่ส่ง LINE ออกไปไหน
-- (คัดลอกไปรันแยกได้ · ins_line_text แค่ "ประกอบข้อความ" คนละตัวกับ ins_line_push ที่เป็นตัวส่ง)
--
--   select r.no, public.ins_line_text(r, '🛡️ มีคำขอประกันใหม่ — ระบบให้คุณดูแล', true) as line_text
--     from public.ins_requests r
--    order by r.created_at desc
--    limit 3;
--
--   -- ต้องขึ้นต้นด้วย [โตโยต้า] หรือ [ฮีโน่] และไม่มี "· ฮีโน่" ซ้ำท้ายชื่อพนักงานอีก
-- ============================================================================
