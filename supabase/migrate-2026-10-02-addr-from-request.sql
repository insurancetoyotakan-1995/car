-- ============================================================================
-- ที่อยู่พนักงานอัปเดตตามใบคำขอล่าสุด — 2026-10-02 (ผู้ใช้สั่ง)
--
--   เดิม: ins_emp_addr มาจากไฟล์ Excel ที่นำเข้าครั้งเดียว
--         พนักงานย้ายบ้าน/ไม่มีในไฟล์ → ปุ่ม "ใช้ที่อยู่เดิมของคุณ" ในฟอร์มได้ของเก่าหรือไม่มีให้เติม
--   ใหม่: ใบที่ "ปิดการขาย" แล้ว → คัดลอกที่อยู่+เบอร์มือถือในใบไปเป็นที่อยู่ของพนักงานคนนั้น
--
--   เงื่อนไข (ครบทุกข้อถึงจะอัปเดต)
--     1) kind = 'self' และ relation = 'self'  — ผู้ทำประกันคือตัวพนักงานเอง
--        (รถของบิดา/มารดา/คู่สมรส/บุตร และลูกค้าแนะนำ = ที่อยู่ของคนอื่น ไม่เอา)
--     2) emp_verified                          — รหัสพนักงานตรงกับทำเนียบ
--     3) มีบ้านเลขที่ ตำบล อำเภอ จังหวัด ครบ
--
--   🔒 ทำไมรอ "ปิดการขาย" ไม่อัปเดตตอนส่งใบ:
--      ฟอร์มไม่มีล็อกอิน ใครรู้รหัสพนักงานก็ส่งใบได้ → ถ้าอัปเดตตอนส่ง
--      คนอื่นเขียนทับที่อยู่ของพนักงานได้ด้วยใบปลอม
--      ใบที่ปิดการขายผ่านมือเจ้าหน้าที่ประกันแล้ว และเป็นที่อยู่ที่ใช้ออกกรมธรรม์จริง
--
--   ⚠️ แถวที่อัปเดตจากใบ มี source = 'request'
--      ไฟล์นำเข้า (ins-emp-addr.sql) ใช้ on conflict do update → รันนำเข้า Excel ซ้ำ
--      จะเขียนทับที่อยู่จากใบด้วยของใน Excel สำหรับคนที่มีในไฟล์
--
-- ปลอดภัยต่อการรันซ้ำ · ไม่แตะ ins_submit / ins_set_status (ใช้ trigger)
-- ============================================================================

begin;

create or replace function public.ins_addr_from_request()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'done' and old.status is distinct from 'done'
     and new.kind = 'self' and new.relation = 'self' and new.emp_verified
     and btrim(coalesce(new.emp_id, ''))   <> ''
     and btrim(coalesce(new.addr, ''))     <> ''
     and btrim(coalesce(new.tambon, ''))   <> ''
     and btrim(coalesce(new.amphoe, ''))   <> ''
     and btrim(coalesce(new.province, '')) <> '' then
    insert into public.ins_emp_addr as a
           (brand, emp_id, addr, moo, road, tambon, amphoe, province, zipcode, phone_mobile, source, updated_at)
    values (new.brand, new.emp_id, btrim(new.addr), btrim(coalesce(new.moo, '')), btrim(coalesce(new.road, '')),
            btrim(new.tambon), btrim(new.amphoe), btrim(new.province), btrim(coalesce(new.zipcode, '')),
            btrim(coalesce(new.phone_mobile, '')), 'request', now())
    on conflict (brand, emp_id) do update set
      addr = excluded.addr, moo = excluded.moo, road = excluded.road, tambon = excluded.tambon,
      amphoe = excluded.amphoe, province = excluded.province, zipcode = excluded.zipcode,
      -- เบอร์ในใบว่าง = คงเบอร์เดิมไว้
      phone_mobile = case when excluded.phone_mobile <> '' then excluded.phone_mobile else a.phone_mobile end,
      source = 'request', updated_at = now();
  end if;
  return new;
end;
$$;
revoke all on function public.ins_addr_from_request() from public, anon, authenticated;

drop trigger if exists ins_requests_addr_sync on public.ins_requests;
create trigger ins_requests_addr_sync
  after update of status on public.ins_requests
  for each row execute function public.ins_addr_from_request();

-- ---------- ใบที่ปิดการขายไปแล้วก่อนหน้านี้ → ใช้ใบล่าสุดของแต่ละคน ----------
insert into public.ins_emp_addr as a
       (brand, emp_id, addr, moo, road, tambon, amphoe, province, zipcode, phone_mobile, source, updated_at)
select distinct on (r.brand, r.emp_id)
       r.brand, r.emp_id, btrim(r.addr), btrim(coalesce(r.moo, '')), btrim(coalesce(r.road, '')),
       btrim(r.tambon), btrim(r.amphoe), btrim(r.province), btrim(coalesce(r.zipcode, '')),
       btrim(coalesce(r.phone_mobile, '')), 'request', now()
  from public.ins_requests r
 where r.status = 'done' and r.kind = 'self' and r.relation = 'self' and r.emp_verified
   and btrim(coalesce(r.emp_id, '')) <> '' and btrim(coalesce(r.addr, '')) <> ''
   and btrim(coalesce(r.tambon, '')) <> '' and btrim(coalesce(r.amphoe, '')) <> ''
   and btrim(coalesce(r.province, '')) <> ''
 order by r.brand, r.emp_id, r.updated_at desc
on conflict (brand, emp_id) do update set
  addr = excluded.addr, moo = excluded.moo, road = excluded.road, tambon = excluded.tambon,
  amphoe = excluded.amphoe, province = excluded.province, zipcode = excluded.zipcode,
  phone_mobile = case when excluded.phone_mobile <> '' then excluded.phone_mobile else a.phone_mobile end,
  source = 'request', updated_at = now();

commit;

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยก — อ่านอย่างเดียว)
--
--   select (select count(*) from pg_trigger where tgname = 'ins_requests_addr_sync') as trigger_ok,   -- ต้องได้ 1
--          (select count(*) from public.ins_emp_addr where source = 'excel')         as จาก_excel,
--          (select count(*) from public.ins_emp_addr where source = 'request')       as จากใบคำขอ;
--
-- ถอนออก:
--   drop trigger if exists ins_requests_addr_sync on public.ins_requests;
--   drop function if exists public.ins_addr_from_request();
--   (แถว source = 'request' ที่อัปเดตไปแล้วจะคงอยู่ — นำเข้า Excel ซ้ำเพื่อกลับเป็นของเดิม)
-- ============================================================================
