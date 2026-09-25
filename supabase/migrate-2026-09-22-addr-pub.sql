-- ============================================================================
-- เปิดให้ฟอร์มลูกค้าดึง "ที่อยู่พนักงาน" ได้ (2026-09-22)
--
-- 📌 ไฟล์นี้เพิ่งถูกนำกลับเข้ารีโปเมื่อ 2026-09-25
--    ของเดิมรันบน prod ตั้งแต่ 22 ก.ย. โดยวางจากแชทตรง ๆ ไม่ได้เก็บเป็นไฟล์ไว้
--    → ถ้าต้องกู้ฐานข้อมูลใหม่จากรีโป ฟังก์ชันนี้จะหายไปเงียบ ๆ แล้วปุ่ม
--      "ดึงข้อมูลที่เคยกรอก" ในฟอร์มจะใช้ไม่ได้โดยไม่มี error ให้เห็น
--    ตรวจว่าตรงกับตัวที่รันอยู่จริงได้ด้วยคำสั่งท้ายไฟล์
--
--   ⚠️ จุดที่ยอมรับความเสี่ยงไว้อย่างตั้งใจ — ฟอร์มลูกค้าไม่มีล็อกอิน (role = anon)
--      ใครรู้รหัสพนักงาน 8 หลัก ก็ดึงที่อยู่บ้านคนนั้นได้ · ผู้ใช้ทราบและยืนยันแล้ว
--   สิ่งที่ทำเพื่อลดความเสี่ยง
--     1) คืนแค่ 7 ช่องที่อยู่ — ไม่คืนชื่อ เบอร์โทร ทะเบียนรถ วันเกิด เลขบัตร
--     2) เพดาน 30 ครั้ง / 10 นาที ต่อ IP → ดูดทั้งองค์กรไม่ได้ในทางปฏิบัติ
--     3) บันทึกทุกครั้งที่ดึงลง ins_addr_log → ตามรอยได้ว่า IP ไหนถามรหัสอะไร
--     4) ตาราง ins_emp_addr ยังไม่มี policy → แตะตารางตรง ๆ ไม่ได้อยู่ดี
--   ปิดฟีเจอร์นี้ทันทีเมื่อไรก็ได้ (ท้ายไฟล์) — หน้าเว็บกลับไปใช้ที่จำในเครื่อง ไม่พัง
--
-- ✅ รันซ้ำได้ · ⚠️ ต้องรันหลัง migrate-2026-09-22-emp-addr.sql
-- ============================================================================
begin;

create table if not exists public.ins_addr_log (
  id         bigserial primary key,
  ip         text not null default '',
  emp_id     text not null default '',
  brand      text not null default 'toyota',
  hit        boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists ins_addr_log_idx on public.ins_addr_log (ip, created_at desc);
alter table public.ins_addr_log enable row level security;
revoke all on public.ins_addr_log from anon, authenticated;
revoke all on sequence public.ins_addr_log_id_seq from anon, authenticated;

create or replace function public.ins_addr_pub(p_emp text, p_brand text default 'toyota')
returns table (addr text, moo text, road text, tambon text, amphoe text, province text, zipcode text)
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_ip     text := coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', '');
  v_id     text := regexp_replace(coalesce(p_emp, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_br     text := public.ins_brand(p_brand);
  v_recent integer;
  v_hit    boolean;
begin
  if length(v_id) < 1 then return; end if;

  select count(*) into v_recent from public.ins_addr_log
   where ip = v_ip and created_at > now() - interval '10 minutes';
  if v_recent >= 30 then
    raise exception 'ดึงข้อมูลถี่เกินไป กรุณารอสักครู่' using errcode = 'P0001';
  end if;

  select true into v_hit from public.ins_emp_addr a
   where a.emp_id = v_id and a.brand = v_br limit 1;
  insert into public.ins_addr_log (ip, emp_id, brand, hit)
  values (v_ip, v_id, v_br, coalesce(v_hit, false));

  return query
    select a.addr, a.moo, a.road, a.tambon, a.amphoe, a.province, a.zipcode
      from public.ins_emp_addr a
     where a.emp_id = v_id and a.brand = v_br;
end;
$$;
revoke all on function public.ins_addr_pub(text, text) from public;
grant execute on function public.ins_addr_pub(text, text) to anon, authenticated;

commit;
notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจว่าไฟล์นี้ตรงกับตัวที่รันอยู่บน prod จริง (คัดลอกไปรันแยก)
--   ถ้าไม่ตรง แปลว่ามีการแก้บนฐานข้อมูลโดยไม่ได้อัปเดตไฟล์ — ให้ยึดของบน prod
--
--   select pg_get_functiondef('public.ins_addr_pub(text,text)'::regprocedure);
--
-- ใช้งานได้ปกติไหม
--   select * from public.ins_addr_pub('11001019');          -- ต้องได้ 1 แถว
--   select count(*) from public.ins_addr_pub('00000000');   -- ต้องได้ 0 ไม่ error
--
-- ใครดึงที่อยู่ไปบ้าง (ไล่ย้อนหลังได้)
--   select created_at, ip, emp_id, brand, hit from public.ins_addr_log
--    order by created_at desc limit 50;
--
-- ปิดฟีเจอร์นี้ (หน้าเว็บกลับไปใช้ที่อยู่ที่จำในเครื่อง ไม่มี error)
--   revoke execute on function public.ins_addr_pub(text, text) from anon;
-- ============================================================================
