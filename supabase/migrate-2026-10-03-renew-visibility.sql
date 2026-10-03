-- ============================================================================
-- รายการต่ออายุ: เจ้าหน้าที่เห็นเฉพาะสาขาของตัวเอง — 2026-10-03 (ผู้ใช้แจ้ง)
--
--   🐞 เดิม (migrate-2026-09-30-renewal-v2): เจ้าหน้าที่เห็น "ของตัวเอง + ทุกคันที่ยังไม่มีผู้ดูแล"
--      → คันที่ไม่มีผู้ดูแลขึ้นกับเจ้าหน้าที่ทุกคน ทุกสาขา (เช่น ลูกค้าสำนักงานใหญ่โผล่ในจอคนท่ามะกา)
--      และไม่กรองแบรนด์ → เจ้าหน้าที่ฮีโน่เห็นรถโตโยต้าที่ไม่มีผู้ดูแลด้วย
--
--   ใหม่ — กติกาเดียวกับการแจกใบ (ins_pick_assignee · migrate-2026-09-23-assign-group)
--     1) แบรนด์ต้องตรงกับแบรนด์ของเจ้าหน้าที่
--     2) มีผู้ดูแล → เห็นเฉพาะผู้ดูแลคนนั้น (คนเดิมได้ก่อน — ผู้ใช้เลือกไว้ 2026-09-23)
--     3) ไม่มีผู้ดูแล (โตโยต้า) → เห็นเฉพาะเจ้าหน้าที่กลุ่มเดียวกับหลักแรกของรหัสพนักงาน
--          1 = สำนักงานใหญ่ · 2 = ท่ามะกา · 3 = พนมทวน
--        กลุ่มนั้นไม่มีเจ้าหน้าที่ที่รับงานอยู่ → เห็นทั้งแผนก (ตกไปทั้งแผนก เหมือนการแจกใบ)
--     4) ผู้ดูแลเดิมถูกปิดบัญชี/ไม่ใช่เจ้าหน้าที่แล้ว → ถือว่ายังไม่มีผู้ดูแล (เดิมคันนั้นหายจากจอทุกคน)
--     บัญชีกลาง (admin) เห็นทุกคันเหมือนเดิม
--
--   คอลัมน์ที่คืนเหมือนเดิมทุกตัว → หน้าเว็บไม่ต้องแก้
--   ตัวฟังก์ชัน = v2 ทุกบรรทัด ยกเว้น CTE own (ผู้ดูแลต้องยัง active) + เงื่อนไข where ท้าย
--
-- ปลอดภัยต่อการรันซ้ำ (create or replace · ชื่อ/พารามิเตอร์/คอลัมน์เดิม)
-- ============================================================================

begin;

create or replace function public.ins_renewals(p_days int default 90)
returns table (
  brand text, emp_id text, emp_name text, plate text, vin text,
  expire_on date, days_left int, phone_mobile text,
  agent_emp_id text, agent_name text, open_no text, open_status text,
  insured_name text, kind text, src_no text
)
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_admin boolean := public.is_ins_admin();
  v_me    text    := public.ins_my_emp();
  v_br    text;
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  select coalesce(s.brand, 'toyota') into v_br from public.ins_staff s where s.emp_id = v_me;

  return query
  with src as (
    -- A) กรมธรรม์ที่ฝ่ายประกันนำเข้าจาก Excel
    select a.brand as s_brand, a.emp_id as s_emp, a.plate as s_plate, a.vin as s_vin,
           a.expire_on as s_end, null::text as s_no, null::text as s_insured,
           null::text as s_phone, 'self'::text as s_kind, null::text as s_agent
      from public.ins_active_policy a
    union all
    -- B) ใบที่ปิดการขายในระบบนี้
    select r.brand, r.emp_id, r.car_plate, r.car_vin,
           coalesce(r.quote_end, r.quote_act_end), r.no,
           nullif(btrim(r.insured_name), ''),   -- ไม่ใส่คำนำหน้า: หน้าเว็บเทียบกับชื่อพนักงาน (ทำเนียบไม่มีคำนำหน้า)
           nullif(btrim(r.phone_mobile), ''), r.kind, r.assigned_to
      from public.ins_requests r
     where r.status = 'done' and coalesce(r.quote_end, r.quote_act_end) is not null
  ),
  keyed as (
    -- รถคันเดียวกัน = ทะเบียนเดียวกัน (ไม่มีทะเบียนใช้เลขตัวรถ · ไม่มีทั้งคู่ = แยกแถวไว้ ไม่เดา)
    select s.*,
           coalesce(nullif(public.ins_plate_key(s.s_plate), ''),
                    nullif(public.ins_vin_key(s.s_vin), ''),
                    'x:' || coalesce(s.s_no, s.s_emp || '|' || s.s_end::text)) as s_key
      from src s
  ),
  latest as (
    -- วันหมดอายุล่าสุดของรถแต่ละคัน · วันเท่ากันให้ใบในระบบชนะ (ข้อมูลครบกว่า Excel)
    select distinct on (k.s_brand, k.s_key) k.*
      from keyed k
     order by k.s_brand, k.s_key, k.s_end desc, (k.s_no is not null) desc
  ),
  pol as (
    select l.* from latest l
     where l.s_end <= public.ins_today() + greatest(coalesce(p_days, 90), 0)
  ),
  own as (
    -- ผู้ดูแล: คนที่ขายใบนั้น → ผู้ดูแลใบล่าสุดของพนักงาน → mapping จาก Excel
    -- 🔑 ใหม่: นับเฉพาะคนที่ยังเป็นเจ้าหน้าที่ (active agent) — ไม่งั้นคันนั้นค้างกับคนที่ออกไปแล้ว ไม่มีใครเห็น
    select p.s_brand as o_brand, p.s_key as o_key,
           coalesce(
             (select s.emp_id from public.ins_staff s
               where s.emp_id = p.s_agent and s.active and s.role = 'agent'),
             (select r.assigned_to from public.ins_requests r
                join public.ins_staff s on s.emp_id = r.assigned_to and s.active and s.role = 'agent'
               where r.emp_id = p.s_emp and r.brand = p.s_brand and r.kind = 'self'
                 and r.status <> 'cancelled' and r.assigned_to is not null
               order by r.created_at desc limit 1),
             (select o.agent_emp_id from public.ins_emp_owner o
                join public.ins_staff s on s.emp_id = o.agent_emp_id and s.active and s.role = 'agent'
               where o.emp_id = p.s_emp and o.brand = p.s_brand)
           ) as o_agent
      from pol p
  ),
  grp as (
    -- กลุ่มสาขาที่ยังมีเจ้าหน้าที่รับงานอยู่ (โตโยต้า) — กลุ่มที่ไม่มีใครรับ ให้ทั้งแผนกเห็น
    select distinct left(s.emp_id, 1) as g
      from public.ins_staff s
     where s.active and s.role = 'agent' and s.takes_new and coalesce(s.brand, 'toyota') = 'toyota'
  )
  select p.s_brand, p.s_emp,
         coalesce(e.name, p.s_emp),
         p.s_plate, p.s_vin, p.s_end,
         (p.s_end - public.ins_today())::int,
         coalesce(p.s_phone, ad.phone_mobile, ''),
         w.o_agent,
         coalesce(ae.name, nullif(split_part(st.note, ' · ', 1), ''), w.o_agent),
         q.no, q.status,
         p.s_insured, p.s_kind, p.s_no
    from pol p
    left join own w                   on w.o_brand = p.s_brand and w.o_key = p.s_key
    left join public.employees e      on e.emp_id = p.s_emp and e.brand = p.s_brand
    left join public.ins_emp_addr ad  on ad.emp_id = p.s_emp and ad.brand = p.s_brand
    left join public.ins_staff st     on st.emp_id = w.o_agent
    left join public.employees ae     on ae.emp_id = w.o_agent and ae.brand = coalesce(st.brand, 'toyota')
    left join lateral (
      -- มีใบของรถคันนี้ที่ยังทำอยู่ไหม (ไม่สนว่าใครยื่น/แบบไหน — รถ 1 คันมีใบค้างได้ใบเดียว)
      select r.no, r.status
        from public.ins_requests r
       where r.brand = p.s_brand
         and r.status not in ('done','cancelled')
         and ((public.ins_plate_key(p.s_plate) <> ''
               and public.ins_plate_key(r.car_plate) = public.ins_plate_key(p.s_plate))
           or (public.ins_vin_key(p.s_vin) <> ''
               and public.ins_vin_key(r.car_vin) = public.ins_vin_key(p.s_vin)))
       order by r.created_at desc limit 1
    ) q on true
   where v_admin
      or (p.s_brand = v_br
          and (w.o_agent = v_me
               or (w.o_agent is null
                   and (p.s_brand <> 'toyota'
                        or left(coalesce(p.s_emp, ''), 1) = left(v_me, 1)
                        or not exists (select 1 from grp where grp.g = left(coalesce(p.s_emp, ''), 1))))))
   order by p.s_end, p.s_emp;
end;
$$;
revoke all on function public.ins_renewals(int) from public, anon;
grant execute on function public.ins_renewals(int) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยก — อ่านอย่างเดียว · SQL Editor รันในนาม postgres ไม่ใช่เจ้าหน้าที่
-- เลยเรียก ins_renewals ตรง ๆ ไม่ได้ → ดูว่าแต่ละคันจะไปขึ้นกับกลุ่มไหน)
--
--   select left(a.emp_id, 1) as กลุ่มของพนักงาน, count(*) as คันที่ไม่มีผู้ดูแล
--     from public.ins_active_policy a
--    where a.brand = 'toyota'
--      and a.expire_on <= public.ins_today() + 90
--      and not exists (select 1 from public.ins_emp_owner o
--                       join public.ins_staff s on s.emp_id = o.agent_emp_id and s.active and s.role = 'agent'
--                      where o.emp_id = a.emp_id and o.brand = a.brand)
--    group by 1 order by 1;
--
--   ทดสอบจริง: ให้เจ้าหน้าที่แต่ละสาขาเปิดหน้าเจ้าหน้าที่ (Ctrl+F5 ไม่จำเป็น — ฝั่งฐานข้อมูลเปลี่ยนอย่างเดียว)
--   คันที่ "ยังไม่มีผู้ดูแล" ต้องเหลือเฉพาะพนักงานที่รหัสขึ้นต้นตรงกับสาขาของตัวเอง
--
-- ย้อนกลับ: รันส่วนที่ 4 ของ migrate-2026-09-30-renewal-v2.sql ซ้ำ
-- ============================================================================
