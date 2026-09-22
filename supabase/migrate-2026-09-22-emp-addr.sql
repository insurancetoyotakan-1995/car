-- ============================================================================
-- ที่อยู่ของพนักงาน จาก Excel ฝ่ายประกัน (2026-09-22)
--
--   ที่มา: ข้อมูลพนักงานประกันยังไม่หมดอายุ.xlsx
--          (บ้านเลขที่ · ถนน · หมู่ · ตำบล · อำเภอ · จังหวัด · เลขไปรษณีย์)
--   นำเข้าด้วย scripts/export-emp-addr.cjs → supabase/ins-emp-addr.sql (gitignore)
--
--   ⚠️⚠️ นี่คือ "ที่อยู่บ้านของพนักงาน" = ข้อมูลส่วนบุคคล จึงล็อกไว้แน่นกว่าตารางอื่น
--     • RLS เปิด และ "ไม่มี policy เลย" → แตะตารางตรง ๆ ไม่ได้ทั้ง anon และ authenticated
--     • อ่านได้ทางเดียวคือ ins_addr_of() ซึ่งจำกัด "เจ้าหน้าที่ประกันที่ล็อกอินแล้ว" เท่านั้น
--     • 🔑 ไม่เปิดให้ฟอร์มสาธารณะ (anon) เพราะฟอร์มไม่มีล็อกอิน
--       ถ้าเปิด ใครรู้รหัสพนักงาน 8 หลักก็ดึงที่อยู่บ้านเขาได้ทันที
--       (ฟอร์มลูกค้าใช้วิธีจำที่อยู่ไว้ในเครื่องผู้กรอกเองแทน — ดู HOUSE_KEY ใน index.html)
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-21-brand.sql
-- ============================================================================

begin;

create table if not exists public.ins_emp_addr (
  brand      text not null default 'toyota',
  emp_id     text not null,
  addr       text not null default '',      -- บ้านเลขที่
  moo        text not null default '',      -- หมู่ (เก็บเฉพาะเลข ตัดคำว่า "ม." ออกแล้ว)
  road       text not null default '',
  tambon     text not null default '',
  amphoe     text not null default '',
  province   text not null default '',
  zipcode    text not null default '',
  source     text not null default 'excel',
  updated_at timestamptz not null default now(),
  primary key (brand, emp_id)
);
alter table public.ins_emp_addr drop constraint if exists ins_emp_addr_brand_chk;
alter table public.ins_emp_addr add constraint ins_emp_addr_brand_chk check (brand in ('toyota','hino'));
alter table public.ins_emp_addr enable row level security;      -- ไม่มี policy = เข้าได้เฉพาะ security definer
revoke all on public.ins_emp_addr from anon, authenticated;

comment on table public.ins_emp_addr is
  'ที่อยู่บ้านพนักงาน (จาก Excel ฝ่ายประกัน) — ข้อมูลส่วนบุคคล อ่านได้เฉพาะเจ้าหน้าที่ประกันผ่าน ins_addr_of()';

-- ---------- อ่านทีละคน (เจ้าหน้าที่ประกันเท่านั้น) ----------
--   ไว้ให้เจ้าหน้าที่ที่คีย์ใบจากกระดาษ ไม่ต้องพิมพ์ที่อยู่ซ้ำ
--   🔑 คืนทีละรหัส ไม่มีทางดึงทั้งตาราง · ไม่ให้ anon เรียกเด็ดขาด
create or replace function public.ins_addr_of(p_emp text, p_brand text default 'toyota')
returns table (addr text, moo text, road text, tambon text, amphoe text, province text, zipcode text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id text := regexp_replace(coalesce(p_emp, ''), '[^0-9A-Za-z_-]', '', 'g');
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  if length(v_id) < 1 then return; end if;
  return query
    select a.addr, a.moo, a.road, a.tambon, a.amphoe, a.province, a.zipcode
      from public.ins_emp_addr a
     where a.emp_id = v_id and a.brand = public.ins_brand(p_brand);
end;
$$;
revoke all on function public.ins_addr_of(text, text) from public, anon;
grant execute on function public.ins_addr_of(text, text) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select (select count(*) from information_schema.tables where table_name = 'ins_emp_addr') as tbl_ok,
--          (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--            where n.nspname='public' and p.proname = 'ins_addr_of')                          as fn_ok,
--          (select count(*) from public.ins_emp_addr)                                         as rows_now;
--   -- ต้องได้ tbl_ok = 1 · fn_ok = 1 · rows_now = 0 (ยังไม่นำเข้า)
--
-- ต่อไปวางไฟล์ supabase/ins-emp-addr.sql เพื่อใส่ข้อมูลจริง
-- ============================================================================
