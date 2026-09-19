-- ============================================================================
-- กรมธรรม์ของพนักงานที่ยังไม่หมดอายุ → นับเป็น "รถคันแรก" ในสิทธิ์รถคันที่ 2 (2026-09-19)
--   ข้อมูลมาจาก Excel ของฝ่ายประกัน (scripts/export-active-policy.cjs → supabase/ins-active-policy.sql)
--   กติกา: กรมธรรม์ที่ "ยังไม่เลยวันหมดอายุ" = พนักงานใช้สิทธิ์คันแรกไปแล้ว
--          → รถคันอื่นที่ยื่นเข้ามา = รถคันที่ 2 (ส่วนลด 10% เงินสด/โอนเท่านั้น)
--          เลยวันหมดอายุแล้ว = ไม่นับ (กลับมาได้สิทธิ์คันแรก)
--          ทะเบียนหรือเลขตัวถังเดียวกับกรมธรรม์เดิม = ต่ออายุรถคันเดิม ไม่นับ
--   "วันนี้" = วันที่ตามเวลาไทย (Asia/Bangkok)
--
-- ✅ รันไฟล์นี้ไฟล์เดียว แล้วค่อยรัน ins-active-policy.sql (ข้อมูล) · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-19-car2.sql
-- 🔒 ตารางใหม่ไม่มี policy (anon/authenticated อ่านตรงไม่ได้) · เก็บแค่ รหัสพนักงาน ทะเบียน เลขตัวถัง วันหมดอายุ
-- ============================================================================

begin;

-- ---------- 1) ตารางกรมธรรม์ที่ยังมีผล ----------
create table if not exists public.ins_active_policy (
  id          bigserial primary key,
  emp_id      text not null,               -- พนักงานเจ้าของสิทธิ์
  plate       text not null default '',    -- ทะเบียนรถ
  vin         text not null default '',    -- เลขตัวถัง
  expire_on   date not null,               -- วันหมดอายุกรมธรรม์ (ค.ศ.)
  source      text not null default 'excel',
  created_at  timestamptz not null default now()
);
create index if not exists ins_active_policy_emp_idx on public.ins_active_policy (emp_id);
alter table public.ins_active_policy enable row level security;
revoke all on public.ins_active_policy from anon, authenticated;
revoke all on sequence public.ins_active_policy_id_seq from anon, authenticated;

create or replace function public.ins_vin_key(p text)
returns text
language sql
immutable
as $$ select upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g')) $$;

create or replace function public.ins_today()
returns date
language sql
stable
as $$ select (now() at time zone 'Asia/Bangkok')::date $$;

-- ---------- 2) ตัวนับกลาง: รวมคำขอในระบบ + กรมธรรม์ที่ยังไม่หมดอายุ ----------
--   รถคันเดียวกันจากทั้ง 2 แหล่ง (ทะเบียนตรงกัน) นับครั้งเดียว
create or replace function public.ins_car_others(p_emp text, p_plate text, p_vin text, p_req uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  with cars as (
    select public.ins_plate_key(r.car_plate) as pk, public.ins_vin_key(r.car_vin) as vk, r.id::text as fb
      from public.ins_requests r
     where r.emp_id = p_emp
       and r.kind = 'self'
       and r.status <> 'cancelled'
       and r.created_at > now() - interval '12 months'
       and (p_req is null or r.id <> p_req)
       and r.covers is distinct from array['act']::text[]
    union all
    select public.ins_plate_key(a.plate), public.ins_vin_key(a.vin), 'p' || a.id
      from public.ins_active_policy a
     where a.emp_id = p_emp
       and a.expire_on >= public.ins_today()
  )
  select count(distinct coalesce(nullif(pk, ''), nullif(vk, ''), fb))::integer
    from cars
   where not (pk <> '' and pk = public.ins_plate_key(p_plate))
     and not (vk <> '' and vk = public.ins_vin_key(p_vin));
$$;

-- ---------- 3) ฟอร์มถาม (เพิ่มเลขตัวถัง — ส่งแค่ทะเบียนก็ยังได้) ----------
drop function if exists public.ins_car2_check(text, text);
create or replace function public.ins_car2_check(p_emp_id text, p_plate text default '', p_vin text default '')
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
  return public.ins_car_others(v_id, left(coalesce(p_plate, ''), 20), left(coalesce(p_vin, ''), 30), null);
end;
$$;

-- ---------- 4) หน้าเจ้าหน้าที่: กรมธรรม์ที่ยังมีผลทั้งหมด (ไว้แสดงในแถบเตือน) ----------
create or replace function public.ins_active_policies()
returns table (emp_id text, plate text, vin text, expire_on date)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  return query
    select a.emp_id, a.plate, a.vin, a.expire_on
      from public.ins_active_policy a
     where a.expire_on >= public.ins_today()
     order by a.emp_id, a.expire_on;
end;
$$;

-- ---------- 5) ข้อความ LINE — เรียกตัวนับรุ่นใหม่ (ส่งเลขตัวถังด้วย) ----------
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
    v_cars := public.ins_car_others(p_req.emp_id, p_req.car_plate, p_req.car_vin, p_req.id);
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

-- ตัวนับรุ่นเก่า (ไม่มีเลขตัวถัง) ไม่ใช้แล้ว
drop function if exists public.ins_car_others(text, text, uuid);

-- ---------- 6) สิทธิ์ ----------
revoke all on function public.ins_vin_key(text)                                 from public, anon, authenticated;
revoke all on function public.ins_today()                                       from public, anon, authenticated;
revoke all on function public.ins_car_others(text, text, text, uuid)            from public, anon, authenticated;
revoke all on function public.ins_line_text(public.ins_requests, text, boolean) from public, anon, authenticated;
revoke all on function public.ins_car2_check(text, text, text)                  from public;
grant execute on function public.ins_car2_check(text, text, text) to anon, authenticated;
revoke all on function public.ins_active_policies()                             from public, anon;
grant execute on function public.ins_active_policies() to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select (select count(*) from pg_proc where proname = 'ins_car2_check') as check_fn,
--          (select count(*) from pg_proc where proname = 'ins_car_others') as count_fn,
--          (select count(*) from information_schema.tables where table_name = 'ins_active_policy') as tbl;
--   -- ต้องได้ check_fn = 1 · count_fn = 1 · tbl = 1
-- ============================================================================
