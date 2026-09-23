-- ============================================================================
-- แจกงานตาม "หลักแรกของรหัสพนักงาน" — 2026-09-23
--
-- กติกาที่ผู้ใช้สั่ง:
--   พนักงานโตโยต้ารหัสขึ้นต้น 1 → แจกให้เจ้าหน้าที่ประกันรหัสขึ้นต้น 1
--   ขึ้นต้น 2 → เจ้าหน้าที่ขึ้นต้น 2 · ขึ้นต้น 3 → เจ้าหน้าที่ขึ้นต้น 3
--
-- ข้อตกลงที่คุยกันไว้ (2026-09-23):
--   1) ไม่มีคนในกลุ่มนั้น / มีแต่ถูกพักแจกหมด → ตกไปให้ทั้งแผนกเหมือนเดิม
--      🔑 ห้ามปล่อยใบค้างไม่มีเจ้าของ เพราะไม่มีใครรับผิดชอบโทรกลับลูกค้า
--   2) พนักงานที่เคยมีเจ้าหน้าที่ดูแลอยู่แล้ว (ใบเก่า / กรมธรรม์เดิมจาก Excel)
--      → ยึดคนเดิมไว้ก่อน แม้รหัสจะไม่ตรงกลุ่ม (ลูกค้าได้คุยกับคนที่รู้เรื่อง)
--      กติกากลุ่มจึงใช้ตอน "แจกใบใหม่ที่ยังไม่เคยมีเจ้าของ" เท่านั้น
--   3) ใช้เฉพาะแบรนด์โตโยต้า · ใบฮีโน่ยังแจกทั้งแผนกแบบเดิม
--
-- ลำดับการตัดสินใจหลังแก้ (บนลงล่าง เจอแล้วหยุด):
--   1. ใบ self: เจ้าหน้าที่คนเดิมจากใบล่าสุดของพนักงานคนนี้
--   2. ใบ self: เจ้าหน้าที่จากข้อมูลกรมธรรม์เดิม (ins_emp_owner)
--   3. ★ ใหม่: คนในกลุ่มรหัสเดียวกัน ที่ถือใบน้อยสุด (เฉพาะโตโยต้า)
--   4. ทั้งแผนก คนที่ถือใบน้อยสุด (เหมือนเดิม)
--
-- ปลอดภัยต่อการรันซ้ำ · ไม่แตะตาราง ไม่แตะข้อมูลเดิม แก้แค่ฟังก์ชันเดียว
-- ย้อนกลับ = รัน migrate-2026-09-21-agent-pause.sql ส่วนที่ 2 ใหม่
-- ============================================================================

begin;

create or replace function public.ins_pick_assignee(p_emp text, p_kind text, p_brand text default 'toyota')
returns text
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v  text;
  vb text := public.ins_brand(p_brand);
  vg text;                       -- หลักแรกของรหัสพนักงานผู้ขอ = รหัสกลุ่ม
begin
  -- 🔑 ล็อกกันยื่นพร้อมกัน 2 ใบแล้วได้คนเดียวกัน (ค้างจนจบทรานแซกชันของ ins_submit)
  perform pg_advisory_xact_lock(hashtext('ins_pick_assignee'));

  if p_kind = 'self' and coalesce(p_emp, '') <> '' then
    -- 1) ใบล่าสุดในระบบนี้ (แบรนด์เดียวกัน)
    select r.assigned_to into v
      from public.ins_requests r
      join public.ins_staff s on s.emp_id = r.assigned_to and s.active and s.role = 'agent' and s.takes_new
     where r.emp_id = p_emp and r.brand = vb and r.kind = 'self' and r.status <> 'cancelled'
     order by r.created_at desc
     limit 1;
    if v is not null then return v; end if;

    -- 2) ข้อมูลกรมธรรม์เดิมจาก Excel
    select o.agent_emp_id into v
      from public.ins_emp_owner o
      join public.ins_staff s on s.emp_id = o.agent_emp_id and s.active and s.role = 'agent' and s.takes_new
     where o.emp_id = p_emp and o.brand = vb;
    if v is not null then return v; end if;
  end if;

  -- 3) ★ กลุ่มตามหลักแรกของรหัส (เฉพาะโตโยต้า) — ใช้กับทั้งใบทำเองและใบแนะนำลูกค้า
  --    ในกลุ่มเดียวกันยังแจกให้คนที่ถือใบน้อยสุดก่อน เสมอกันสุ่ม (นับใบทุกแบรนด์ = ภาระงานจริง)
  if vb = 'toyota' and left(coalesce(p_emp, ''), 1) ~ '^[0-9]$' then
    vg := left(p_emp, 1);
    select s.emp_id into v
      from public.ins_staff s
      left join public.ins_requests r
             on r.assigned_to = s.emp_id and r.status <> 'cancelled'
     where s.active and s.role = 'agent' and s.takes_new
       and left(s.emp_id, 1) = vg
     group by s.emp_id
     order by count(r.id), random()
     limit 1;
    if v is not null then return v; end if;
  end if;

  -- 4) ทั้งแผนก: ใครมีใบสะสมน้อยสุดได้ก่อน เสมอกันสุ่ม
  --    ถึงตรงนี้แปลว่ากลุ่มนั้นไม่มีคนรับ — ปล่อยใบไม่มีเจ้าของไม่ได้ ต้องมีคนถือเสมอ
  select s.emp_id into v
    from public.ins_staff s
    left join public.ins_requests r
           on r.assigned_to = s.emp_id and r.status <> 'cancelled'
   where s.active and s.role = 'agent' and s.takes_new
   group by s.emp_id
   order by count(r.id), random()
   limit 1;
  return v;
end;
$$;

revoke all on function public.ins_pick_assignee(text, text, text) from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยก — อ่านอย่างเดียว ไม่แก้ข้อมูล)
--
-- A) เจ้าหน้าที่ประกันแต่ละกลุ่มมีใครบ้าง / กลุ่มไหนยังไม่มีคนรับเลย
--   select left(s.emp_id,1) as กลุ่ม,
--          count(*) filter (where s.takes_new) as รับงานใหม่,
--          count(*) filter (where not s.takes_new) as พักแจก,
--          string_agg(coalesce(e.name, s.emp_id), ', ' order by s.emp_id) as รายชื่อ
--     from public.ins_staff s
--     left join public.employees e on e.emp_id = s.emp_id and e.brand = 'toyota'
--    where s.active and s.role = 'agent'
--    group by 1 order by 1;
--
-- B) พนักงานโตโยต้าแต่ละกลุ่มมีกี่คน (ดูว่ากลุ่มไหนจะมีงานเข้าเยอะ)
--   select left(emp_id,1) as กลุ่ม, count(*) as จำนวนพนักงาน
--     from public.employees where brand = 'toyota' group by 1 order by 1;
--
-- C) ลองแจกจริงโดยไม่บันทึก (ต้องอยู่ใน transaction แล้ว rollback)
--   begin;
--     select '1xxxxxxx' as ผู้ขอ, public.ins_pick_assignee('11001234','refer','toyota') as ได้คนนี้
--     union all select '2xxxxxxx', public.ins_pick_assignee('21001234','refer','toyota')
--     union all select '3xxxxxxx', public.ins_pick_assignee('31001234','refer','toyota')
--     union all select 'ฮีโน่ (ไม่ใช้กฎกลุ่ม)', public.ins_pick_assignee('11001234','refer','hino');
--   rollback;
-- ============================================================================
