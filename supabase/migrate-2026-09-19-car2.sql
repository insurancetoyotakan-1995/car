-- ============================================================================
-- แจ้งเตือน "สิทธิ์รถคันที่ 2" (2026-09-19)
--   สวัสดิการพนักงาน: สิทธิ์ 1 คน 1 คัน · คันที่ 2 ขึ้นไป ส่วนลด 10% ชำระเงินสด/โอนเท่านั้น
--   ระบบนับว่าพนักงานคนนี้มีคำขอ "ทำประกันเอง" ของรถคันอื่นอยู่แล้วกี่คัน แล้วแจ้ง
--     • พนักงาน — ในฟอร์ม (index.html) หลังกรอกรหัสพนักงาน / ทะเบียนรถ
--     • เจ้าหน้าที่ — ในข้อความ LINE ตอนมีคำขอใหม่ (หน้า staff.html นับเองจากรายการที่เห็น)
--
--   กติกานับ "รถคันอื่น" (ins_car_others)
--     • แบบคำขอ "พนักงานทำประกันเอง" ของรหัสพนักงานเดียวกัน · ไม่นับใบยกเลิก
--     • ยื่นภายใน 12 เดือนล่าสุด (รอบกรมธรรม์ 1 ปี)
--     • ทะเบียนเดียวกัน = รถคันเดียวกัน (ต่ออายุ/ยื่นซ้ำ) ไม่นับ · เทียบแบบตัดช่องว่าง - .
--     • ใบที่ขอแค่ พ.ร.บ. อย่างเดียวไม่นับ (ส่วนลดสวัสดิการคิดเฉพาะภาคสมัครใจ)
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ✅ ไม่แตะตาราง/วิว/ins_submit — เพิ่มฟังก์ชัน + แก้ข้อความ LINE (ins_line_text) เท่านั้น
-- 🔒 ฟังก์ชันที่ฟอร์มสาธารณะเรียก (ins_car2_check) คืน "ตัวเลขตัวเดียว" — ไม่คืนเลขที่ใบ/ทะเบียน/ชื่อใด ๆ
-- ============================================================================

begin;

-- ---------- 1) ตัวนับกลาง (ใช้ภายในเท่านั้น) ----------
create or replace function public.ins_plate_key(p text)
returns text
language sql
immutable
as $$ select regexp_replace(coalesce(p, ''), '[[:space:].-]', '', 'g') $$;

create or replace function public.ins_car_others(p_emp text, p_plate text, p_req uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(distinct coalesce(nullif(public.ins_plate_key(r.car_plate), ''), r.id::text))::integer
    from public.ins_requests r
   where r.emp_id = p_emp
     and r.kind = 'self'
     and r.status <> 'cancelled'
     and r.created_at > now() - interval '12 months'
     and (p_req is null or r.id <> p_req)
     and r.covers is distinct from array['act']::text[]
     and (public.ins_plate_key(p_plate) = '' or public.ins_plate_key(r.car_plate) <> public.ins_plate_key(p_plate));
$$;

-- ---------- 2) ให้ฟอร์มถาม: "รหัสนี้มีรถคันอื่นที่ทำประกันเองแล้วกี่คัน" ----------
--   p_plate = ทะเบียนคันที่กำลังกรอก (ว่างได้) → ทะเบียนเดียวกันไม่นับ (ต่ออายุคันเดิม)
create or replace function public.ins_car2_check(p_emp_id text, p_plate text default '')
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
begin
  if length(v_id) < 4 then return 0; end if;
  return public.ins_car_others(v_id, left(coalesce(p_plate, ''), 20), null);
end;
$$;

-- ---------- 3) ข้อความ LINE ถึงเจ้าหน้าที่ — เพิ่มบรรทัดเตือนรถคันที่ 2 ----------
--   (เหมือนเดิมทุกบรรทัด เพิ่มแค่บรรทัด ⚠️ ตอนพนักงานมีรถคันอื่นอยู่แล้ว)
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
begin
  if p_with_agent then
    select coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id) into v_agent
      from public.ins_staff s left join public.employees e on e.emp_id = s.emp_id
     where s.emp_id = p_req.assigned_to;
  end if;
  if not v_refer and coalesce(p_req.emp_id, '') <> '' then
    v_cars := public.ins_car_others(p_req.emp_id, p_req.car_plate, p_req.id);
  end if;
  return p_head
    || E'\nเลขที่: ' || p_req.no
    || E'\nแบบคำขอ: ' || case when v_refer then 'แนะนำลูกค้าทั่วไป' else 'พนักงานทำประกันเอง' end
    || E'\n' || case when v_refer then 'ลูกค้า: ' else 'ผู้ทำประกัน: ' end || regexp_replace(p_req.insured_name, '\s+', ' ', 'g')
    || E'\nโทร: ' || coalesce(nullif(p_req.phone_mobile, ''), '-')
    || E'\n' || case when v_refer then 'ผู้แนะนำ: ' else 'พนักงาน: ' end
    || regexp_replace(p_req.emp_name, '\s+', ' ', 'g')
    || case when coalesce(p_req.emp_dept, '') <> '' then ' (' || p_req.emp_dept || ')' else '' end
    || case when p_req.emp_verified then '' else ' · รหัสยังไม่ยืนยัน' end
    || case when v_cars > 0
            then E'\n⚠️ รถคันที่ ' || (v_cars + 1) || ' ของพนักงาน — สิทธิ์ส่วนลด 10% เงินสด/โอนเท่านั้น'
            else '' end
    || case when p_with_agent then E'\nผู้ดูแล: ' || coalesce(v_agent, 'ยังไม่มี') else '' end
    || E'\n\nเปิดดู: https://insurancetoyotakan-1995.github.io/car/staff.html?no=' || p_req.no;
end;
$$;

-- ---------- 4) สิทธิ์ ----------
revoke all on function public.ins_plate_key(text)                               from public, anon, authenticated;
revoke all on function public.ins_car_others(text, text, uuid)                  from public, anon, authenticated;
revoke all on function public.ins_line_text(public.ins_requests, text, boolean) from public, anon, authenticated;
revoke all on function public.ins_car2_check(text, text)                        from public;
grant execute on function public.ins_car2_check(text, text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select count(*) as fn_count from pg_proc
--    where proname in ('ins_plate_key', 'ins_car_others', 'ins_car2_check');
--   -- ต้องได้ fn_count = 3
--   select public.ins_car2_check('00000000');   -- รหัสที่ไม่มีคำขอ → ต้องได้ 0
-- ============================================================================
