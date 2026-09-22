-- ============================================================================
-- แผนกประกันแบ่ง 2 ทีม + ชื่อหัวหน้าทีมบนช่อง "ผู้ตรวจสอบ" ของใบค่าคอม (2026-09-22)
--
--   ทีม 1 — หัวหน้า สมชัย ผดุงวิทย์วัฒนา (11001032)
--     11001124 พัทธิยา เผ่าแพร · 11001118 สาวิตรี ทับทิมเทศ · 11001019 จุฑารัตน์ สารแดง
--     21001006 เพ็ญพักตร์ เสมทับ · 11001050 มลฤทัย ฉิมเชื้อ
--   ทีม 2 — หัวหน้า กุลธิภัสร์ เกียรติกรสิทธิ์ (11001246)
--     11001094 ธัญรัศม์ กิตติภัทร์โชคสิริ · 11001109 สุชาดา อ่อนน้อม · 11001031 เปรมสินี เท่าเทียม
--     11001020 กัญญา ทองปลอด · 31001003 ยุภา ใคร่ครวญ   ← เพิ่มใหม่ในไฟล์นี้ (ผู้ใช้ยืนยัน 2026-09-22)
--
--   ⚠️⚠️ 2 คนที่เพิ่มใหม่ยัง "เข้าระบบไม่ได้" จนกว่าจะมีบัญชี Auth
--        ผู้ใช้ต้องสร้างเองที่ Supabase → Authentication → Users → Add user
--          อีเมล 11001020@staff.toyotakan  และ  31001003@staff.toyotakan
--          ✅ ต้องติ๊ก "Auto Confirm User"
--        (ไฟล์นี้ให้สิทธิ์ในตาราง ins_staff ได้ แต่สร้างบัญชี/ตั้งรหัสผ่านให้ไม่ได้)
--
--   🔑 หัวหน้าทีมไม่รับใบใหม่อยู่แล้ว (takes_new = false จาก migrate-2026-09-21-agent-pause.sql)
--      แต่ใบเก่าที่เคยแจกไปยังเป็นของเขา → ถ้าใบไหนหัวหน้าเป็นผู้รับเงินเอง
--      ช่องผู้ตรวจสอบจะ "เว้นว่าง" ไม่ใส่ชื่อตัวเอง (ตรวจงานจ่ายเงินของตัวเองไม่ได้)
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-21-agent-pause.sql
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ทีม ----------
alter table public.ins_staff add column if not exists team smallint;
alter table public.ins_staff add column if not exists is_lead boolean not null default false;
alter table public.ins_staff drop constraint if exists ins_staff_team_chk;
alter table public.ins_staff add constraint ins_staff_team_chk check (team is null or team in (1, 2));

comment on column public.ins_staff.team    is 'ทีมในแผนกประกัน (1 หรือ 2) · null = ยังไม่จัดทีม';
comment on column public.ins_staff.is_lead is 'true = หัวหน้าทีม → ชื่อขึ้นช่อง "ผู้ตรวจสอบ" บนใบค่าคอมของลูกทีม';

-- ---------- 2) เพิ่มสมาชิกใหม่เข้าหลังบ้าน ----------
--   note = "ชื่อ · ตำแหน่ง" (ส่วนแรกใช้เป็นชื่อสำรองเวลาหาในทำเนียบไม่เจอ)
--   ไม่แตะ active/role/takes_new ของคนเดิม — ค่าตั้งต้นคือ ใช้งานได้ · role=agent · รับใบใหม่
insert into public.ins_staff (emp_id, note) values
  ('11001020', 'กัญญา ทองปลอด · เจ้าหน้าที่ขายประกันภัย'),
  ('31001003', 'ยุภา ใคร่ครวญ · เจ้าหน้าที่ขายประกันภัย')
on conflict (emp_id) do update set note = excluded.note;

-- ---------- 3) จัดทีม ----------
update public.ins_staff set team = 1, is_lead = (emp_id = '11001032')
 where emp_id in ('11001032','11001124','11001118','11001019','21001006','11001050');

update public.ins_staff set team = 2, is_lead = (emp_id = '11001246')
 where emp_id in ('11001246','11001094','11001109','11001031','11001020','31001003');

-- ---------- 4) ทีม + ชื่อหัวหน้า สำหรับหน้าเว็บ ----------
--   คืนเฉพาะ "โครงทีมของแผนก" — ไม่มียอดงาน ไม่มีข้อมูลลูกค้า
--   เจ้าหน้าที่ทุกคนเรียกได้ (ต่างจาก ins_agents ที่จำกัดเฉพาะบัญชีกลาง เพราะมียอดงานติดมา)
--   เพราะเจ้าหน้าที่ต้องพิมพ์ใบค่าคอมของตัวเอง ซึ่งต้องมีชื่อหัวหน้าทีมอยู่บนใบ
create or replace function public.ins_teams()
returns table (emp_id text, team smallint, lead_emp_id text, lead_name text)
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
    with lead as (
      select s.team,
             s.emp_id as lead_emp_id,
             coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id) as lead_name
        from public.ins_staff s
        left join public.employees e on e.emp_id = s.emp_id and e.brand = 'toyota'
       where s.is_lead and s.team is not null
    )
    select s.emp_id, s.team, l.lead_emp_id, l.lead_name
      from public.ins_staff s
      join lead l on l.team = s.team
     where s.team is not null;
end;
$$;
revoke all on function public.ins_teams() from public, anon;
grant execute on function public.ins_teams() to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--
--   -- ก) ใครอยู่ทีมไหน
--   select team, is_lead, emp_id, split_part(note, ' · ', 1) as ชื่อ
--     from public.ins_staff where role = 'agent' order by team nulls last, is_lead desc, emp_id;
--   -- ทีม 1 ต้องได้ 6 คน (หัวหน้า 11001032) · ทีม 2 ได้ 6 คน (หัวหน้า 11001246) · ที่เหลือ team = null
--
--   -- ข) ชื่อหัวหน้าที่จะขึ้นบนใบค่าคอม
--   select * from public.ins_teams() order by team, emp_id;
-- ============================================================================
