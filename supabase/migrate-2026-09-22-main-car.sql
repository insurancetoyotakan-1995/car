-- ============================================================================
-- "คันหลัก" ของพนักงาน — เจ้าหน้าที่กำหนดเอง (2026-09-22)
--
--   กติกาที่ผู้ใช้ยืนยัน: คันแรก (คันหลัก) ได้สวัสดิการเต็ม เช่นลดเบี้ย 15%
--                        คันที่ 2 ขึ้นไป ลด 10% · ชำระเงินสด/โอนเท่านั้น
--
--   ปัญหาของเดิม: ระบบนับแค่ "มีรถคันอื่นที่ยังมีกรมธรรม์อยู่ไหม" → พนักงานที่มีรถ 2 คัน
--   เวลาต่อคัน A เห็นคัน B ยังมีประกัน → บังคับ 10% · ต่อคัน B เห็นคัน A → บังคับ 10% อีก
--   ผลคือ "ไม่มีคันไหนได้ 15% เลย" ซึ่งไม่ตรงกติกา
--
--   ทางแก้: เก็บว่าพนักงานคนนี้ให้คันไหนเป็นคันหลัก (1 คนต่อ 1 คันต่อแบรนด์)
--     • คันหลัก        → ไม่บังคับ เลือกสวัสดิการได้ตามปกติ (รวม 15%)
--     • ไม่ใช่คันหลัก   → บังคับ 10% เหมือนเดิม
--     • ยังไม่ได้กำหนด → บังคับ 10% ไว้ก่อน (ปลอดภัยกว่าการแจก 15% ให้ทุกคัน)
--       หน้าเว็บจะขึ้นปุ่มให้เจ้าหน้าที่กำหนด
--
--   🔑 เทียบรถด้วย "ทะเบียนหรือเลขตัวถัง" ผ่าน ins_plate_key / ins_vin_key
--      เหมือนที่ ins_car_others ใช้ เพื่อให้เว้นวรรค/ขีดต่างกันยังถือเป็นคันเดียวกัน
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-21-brand.sql
-- ============================================================================

begin;

-- ---------- 1) ตารางคันหลัก ----------
create table if not exists public.ins_main_car (
  brand   text not null,
  emp_id  text not null,
  plate   text not null default '',
  vin     text not null default '',
  set_by  text not null default '',            -- รหัสเจ้าหน้าที่ที่กำหนด (ตามรอยได้)
  set_at  timestamptz not null default now(),
  primary key (brand, emp_id)                  -- 1 คน 1 คันหลัก ต่อแบรนด์
);
alter table public.ins_main_car drop constraint if exists ins_main_car_brand_chk;
alter table public.ins_main_car add constraint ins_main_car_brand_chk check (brand in ('toyota','hino'));
alter table public.ins_main_car enable row level security;    -- ไม่มี policy = เข้าได้เฉพาะฟังก์ชัน security definer
revoke all on public.ins_main_car from anon, authenticated;

comment on table public.ins_main_car is
  'รถคันหลักของพนักงาน (เจ้าหน้าที่กำหนด) — คันหลักได้สวัสดิการเต็ม คันอื่นบังคับลด 10%';

-- ---------- 2) หน้าเว็บอ่านรายการคันหลัก ----------
create or replace function public.ins_main_cars()
returns table (brand text, emp_id text, plate text, vin text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.is_ins_staff() or public.ins_is_viewer()) then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกันและบัญชีดูอย่างเดียว)' using errcode = 'P0001';
  end if;
  return query select m.brand, m.emp_id, m.plate, m.vin from public.ins_main_car m;
end;
$$;
revoke all on function public.ins_main_cars() from public, anon;
grant execute on function public.ins_main_cars() to authenticated;

-- ---------- 3) กำหนด / ยกเลิก คันหลัก จากใบคำขอ ----------
--   p_on = true  → ให้รถของใบนี้เป็นคันหลักของพนักงานคนนี้ (ทับคันเดิมถ้ามี)
--   p_on = false → ยกเลิก แต่ "เฉพาะเมื่อคันหลักที่บันทึกไว้คือคันของใบนี้"
--                  (กันเผลอลบคันหลักที่เป็นรถคันอื่น)
create or replace function public.ins_set_main_car(p_req uuid, p_on boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r      record;
  v_pk   text;
  v_vk   text;
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;

  select q.emp_id, q.kind, q.brand, q.car_plate, q.car_vin
    into r
    from public.ins_requests q
   where q.id = p_req and public.ins_can_see(q.assigned_to);
  if not found then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;
  if r.kind <> 'self' then
    raise exception 'ใบแบบแนะนำลูกค้าไม่เกี่ยวกับสิทธิ์สวัสดิการพนักงาน' using errcode = 'P0001';
  end if;
  if coalesce(r.emp_id, '') = '' then
    raise exception 'ใบนี้ไม่มีรหัสพนักงาน' using errcode = 'P0001';
  end if;
  v_pk := public.ins_plate_key(r.car_plate);
  v_vk := public.ins_vin_key(r.car_vin);
  if v_pk = '' and v_vk = '' then
    raise exception 'ใบนี้ยังไม่มีทะเบียนรถหรือเลขตัวถัง — กรอกก่อนกำหนดคันหลัก' using errcode = 'P0001';
  end if;

  if p_on then
    insert into public.ins_main_car (brand, emp_id, plate, vin, set_by, set_at)
    values (r.brand, r.emp_id, coalesce(r.car_plate,''), coalesce(r.car_vin,''),
            coalesce(public.ins_my_emp(), ''), now())
    on conflict (brand, emp_id) do update
      set plate = excluded.plate, vin = excluded.vin,
          set_by = excluded.set_by, set_at = excluded.set_at;
  else
    delete from public.ins_main_car m
     where m.brand = r.brand and m.emp_id = r.emp_id
       and ((v_pk <> '' and public.ins_plate_key(m.plate) = v_pk)
         or (v_vk <> '' and public.ins_vin_key(m.vin) = v_vk));
  end if;

  return jsonb_build_object('ok', true, 'on', p_on);
end;
$$;
revoke all on function public.ins_set_main_car(uuid, boolean) from public, anon;
grant execute on function public.ins_set_main_car(uuid, boolean) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--
--   -- ก) ตาราง + ฟังก์ชันครบ
--   select (select count(*) from information_schema.tables
--            where table_name = 'ins_main_car')                                as tbl_ok,
--          (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--            where n.nspname='public' and p.proname = 'ins_main_cars')          as read_fn,
--          (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--            where n.nspname='public' and p.proname = 'ins_set_main_car')       as set_fn;
--   -- ต้องได้ 1 ทุกช่อง
--
--   -- ข) ใครถูกกำหนดคันหลักไว้แล้ว (ตอนแรกยังว่าง — เจ้าหน้าที่กำหนดจากหน้าเว็บ)
--   select * from public.ins_main_car order by brand, emp_id;
-- ============================================================================
