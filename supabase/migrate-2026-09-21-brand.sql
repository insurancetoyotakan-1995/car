-- ============================================================================
-- แยกแบรนด์ โตโยต้า / ฮีโน่ ในระบบเดียว (2026-09-21)
--
--   ทำไมต้องแยก: รหัสพนักงานของ 2 บริษัท "ซ้ำกันจริง" (47 คนของฮีโน่ ชนกับโตโยต้า 29 คน
--   และเป็นคนละคนทั้งหมด เช่น 11001001 ฮีโน่ = นภัสวรรณ ซิบเข · โตโยต้า = เสกสรรค์ โพธิ์ศรี)
--   → กุญแจของทำเนียบพนักงานต้องเป็น (แบรนด์ + รหัส) ไม่ใช่รหัสเดี่ยว ๆ
--     ไม่งั้นฟอร์มจะขึ้นชื่อผิดบริษัท และสิทธิ์รถคันที่ 2 / ล็อกต่ออายุจะนับข้ามบริษัทกัน
--
--   เงื่อนไขทุกข้อ "เหมือนกันทั้ง 2 แบรนด์" (ผู้ใช้ยืนยัน) — ไฟล์นี้แค่ทำให้มันนับแยกกัน
--     • ข้อมูลเดิมทั้งหมดกลายเป็น brand = 'toyota' อัตโนมัติ (default) — ของเก่าไม่กระทบ
--     • เลขที่ใบ: โตโยต้า INS-YYMM-nnn (เหมือนเดิม) · ฮีโน่ HIN-YYMM-nnn (คนละชุดเลขรัน)
--     • เจ้าหน้าที่ประกันยังเป็นทีมเดียวกัน เห็นทั้ง 2 แบรนด์ในหน้าเดียว (มีตัวกรอง)
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-21-car-lock.sql
-- 🔑 ins_submit ไม่เขียนใหม่ทั้งตัว — "แทนข้อความ" ในตัวที่อยู่บน prod ตอนนี้
--    (แพตเทิร์นเดียวกับ car-lock.sql) · หาจุดไม่เจอ = หยุดทั้งไฟล์ ไม่แก้ครึ่ง ๆ
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์ brand + กุญแจใหม่ ----------

create or replace function public.ins_brand(p text)
returns text
language sql
immutable
as $$ select case when lower(btrim(coalesce(p, ''))) = 'hino' then 'hino' else 'toyota' end $$;

alter table public.employees         add column if not exists brand text not null default 'toyota';
alter table public.ins_requests      add column if not exists brand text not null default 'toyota';
alter table public.ins_active_policy add column if not exists brand text not null default 'toyota';
alter table public.ins_emp_owner     add column if not exists brand text not null default 'toyota';

do $b$
declare t text;
begin
  foreach t in array array['employees','ins_requests','ins_active_policy','ins_emp_owner'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_brand_chk');
    execute format('alter table public.%I add constraint %I check (brand in (''toyota'',''hino''))',
                   t, t || '_brand_chk');
  end loop;
end $b$;

-- ทำเนียบพนักงาน + ผู้ดูแลประจำตัว: กุญแจหลักเป็น (brand, emp_id)
do $b$
declare
  v_tbl text;
  v_pk  text;
  v_cols text;
begin
  foreach v_tbl in array array['employees','ins_emp_owner'] loop
    select c.conname,
           (select string_agg(a.attname, ',' order by k.ord)
              from unnest(c.conkey) with ordinality as k(attnum, ord)
              join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum)
      into v_pk, v_cols
      from pg_constraint c
     where c.conrelid = ('public.' || v_tbl)::regclass and c.contype = 'p';
    if v_cols = 'brand,emp_id' then
      raise notice '%: กุญแจหลักเป็น (brand, emp_id) อยู่แล้ว — ข้าม', v_tbl;
    else
      if v_pk is not null then
        execute format('alter table public.%I drop constraint %I', v_tbl, v_pk);
      end if;
      execute format('alter table public.%I add primary key (brand, emp_id)', v_tbl);
    end if;
  end loop;
end $b$;

create index if not exists ins_requests_brand_idx      on public.ins_requests (brand, emp_id);
create index if not exists ins_active_policy_brand_idx on public.ins_active_policy (brand, emp_id);

-- ---------- 2) ค้นชื่อพนักงาน — ต้องบอกแบรนด์มาด้วย ----------
--   ตัวเก่า (1 พารามิเตอร์) ต้องทิ้ง ไม่งั้นเรียกด้วยอาร์กิวเมนต์เดียวแล้ว Postgres เลือกไม่ถูก
drop function if exists public.ins_lookup_emp(text);
create or replace function public.ins_lookup_emp(p_emp_id text, p_brand text default 'toyota')
returns table (found boolean, name text, dept text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_br text := public.ins_brand(p_brand);
  r    record;
begin
  -- ฮีโน่มีพนักงานรหัสสั้น (เช่น '1') จึงผ่อนเป็นอย่างน้อย 1 ตัว แต่ยังคืนแค่ทีละคน
  if length(v_id) < 1 then
    return query select false, ''::text, ''::text;
    return;
  end if;
  select e.name, e.dept into r from public.employees e
   where e.emp_id = v_id and e.brand = v_br and e.active is true;
  if not found then
    return query select false, ''::text, ''::text;
  else
    return query select true, r.name, r.dept;
  end if;
end;
$$;

-- ---------- 3) ตัวนับรถคันอื่น / ด่านสิทธิ์ — นับแยกแบรนด์ ----------
drop function if exists public.ins_car_others(text, text, text, uuid);
create or replace function public.ins_car_others(p_emp text, p_plate text, p_vin text, p_req uuid,
                                                 p_brand text default 'toyota')
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
       and r.brand = public.ins_brand(p_brand)
       and r.kind = 'self'
       and r.status <> 'cancelled'
       and r.created_at > now() - interval '12 months'
       and (p_req is null or r.id <> p_req)
       and r.covers is distinct from array['act']::text[]
    union all
    select public.ins_plate_key(a.plate), public.ins_vin_key(a.vin), 'p' || a.id
      from public.ins_active_policy a
     where a.emp_id = p_emp
       and a.brand = public.ins_brand(p_brand)
       and a.expire_on >= public.ins_today()
  )
  select count(distinct coalesce(nullif(pk, ''), nullif(vk, ''), fb))::integer
    from cars
   where not (pk <> '' and pk = public.ins_plate_key(p_plate))
     and not (vk <> '' and vk = public.ins_vin_key(p_vin));
$$;

drop function if exists public.ins_car2_check(text, text, text);
create or replace function public.ins_car2_check(p_emp_id text, p_plate text default '',
                                                 p_vin text default '', p_brand text default 'toyota')
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
begin
  if length(v_id) < 1 then return 0; end if;
  return public.ins_car_others(v_id, left(coalesce(p_plate, ''), 20), left(coalesce(p_vin, ''), 30),
                               null, public.ins_brand(p_brand));
end;
$$;

drop function if exists public.ins_car_gate(text, text, text);
create or replace function public.ins_car_gate(p_emp_id text, p_plate text default '',
                                               p_vin text default '', p_brand text default 'toyota')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c_open  int := 30;                                   -- ยื่นต่ออายุได้ล่วงหน้ากี่วันก่อนหมดอายุ
  v_id    text := regexp_replace(coalesce(p_emp_id, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_br    text := public.ins_brand(p_brand);
  v_pk    text := public.ins_plate_key(p_plate);
  v_vk    text := public.ins_vin_key(p_vin);
  v_today date := public.ins_today();
  v_pol   record;
  v_req   record;
  v_cars  int;
begin
  if length(v_id) < 1 then
    return jsonb_build_object('state', 'first', 'cars', 0, 'needReason', false);
  end if;
  v_cars := public.ins_car_others(v_id, coalesce(p_plate, ''), coalesce(p_vin, ''), null, v_br);

  -- คำขอของ "รถคันเดียวกัน" ที่ยังค้างอยู่ = ห้ามยื่นซ้ำ
  if v_pk <> '' or v_vk <> '' then
    select r.created_at, r.status into v_req
      from public.ins_requests r
     where r.emp_id = v_id and r.brand = v_br and r.kind = 'self'
       and r.status in ('new','contacted','quoted')
       and ((v_pk <> '' and public.ins_plate_key(r.car_plate) = v_pk)
         or (v_vk <> '' and public.ins_vin_key(r.car_vin) = v_vk))
     order by r.created_at desc limit 1;
    if found then
      return jsonb_build_object('state', 'pending', 'cars', v_cars, 'needReason', false,
                                'since', v_req.created_at::date);
    end if;

    -- กรมธรรม์ของรถคันเดียวกันที่ยังไม่หมดอายุ → ต่อได้เมื่อเหลือไม่เกิน c_open วัน
    select a.plate, a.expire_on into v_pol
      from public.ins_active_policy a
     where a.emp_id = v_id
       and a.brand = v_br
       and a.expire_on >= v_today
       and ((v_pk <> '' and public.ins_plate_key(a.plate) = v_pk)
         or (v_vk <> '' and public.ins_vin_key(a.vin) = v_vk))
     order by a.expire_on limit 1;
    if found then
      return jsonb_build_object(
        'state',      case when v_today >= v_pol.expire_on - c_open then 'renew' else 'early' end,
        'cars',       v_cars,
        'needReason', false,
        'plate',      v_pol.plate,
        'expireOn',   v_pol.expire_on,
        'openFrom',   v_pol.expire_on - c_open,
        'daysLeft',   (v_pol.expire_on - c_open) - v_today);
    end if;
  end if;

  if v_cars > 0 then
    return jsonb_build_object('state', 'add', 'cars', v_cars, 'needReason', true);
  end if;
  return jsonb_build_object('state', 'first', 'cars', 0, 'needReason', false);
end;
$$;

-- ---------- 4) ผู้ดูแลประจำตัวพนักงาน — ผูกตามแบรนด์ ----------
drop function if exists public.ins_pick_assignee(text, text);
create or replace function public.ins_pick_assignee(p_emp text, p_kind text, p_brand text default 'toyota')
returns text
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v  text;
  vb text := public.ins_brand(p_brand);
begin
  -- 🔑 ล็อกกันยื่นพร้อมกัน 2 ใบแล้วได้คนเดียวกัน (ค้างจนจบทรานแซกชันของ ins_submit)
  perform pg_advisory_xact_lock(hashtext('ins_pick_assignee'));

  if p_kind = 'self' and coalesce(p_emp, '') <> '' then
    -- 1) ใบล่าสุดในระบบนี้ (แบรนด์เดียวกัน)
    select r.assigned_to into v
      from public.ins_requests r
      join public.ins_staff s on s.emp_id = r.assigned_to and s.active and s.role = 'agent'
     where r.emp_id = p_emp and r.brand = vb and r.kind = 'self' and r.status <> 'cancelled'
     order by r.created_at desc
     limit 1;
    if v is not null then return v; end if;

    -- 2) ข้อมูลกรมธรรม์เดิมจาก Excel
    select o.agent_emp_id into v
      from public.ins_emp_owner o
      join public.ins_staff s on s.emp_id = o.agent_emp_id and s.active and s.role = 'agent'
     where o.emp_id = p_emp and o.brand = vb;
    if v is not null then return v; end if;
  end if;

  -- 3) ใครมีใบสะสมน้อยสุดได้ก่อน เสมอกันสุ่ม (นับรวมทุกแบรนด์ — เจ้าหน้าที่ทีมเดียวกัน)
  select s.emp_id into v
    from public.ins_staff s
    left join public.ins_requests r
           on r.assigned_to = s.emp_id and r.status <> 'cancelled'
   where s.active and s.role = 'agent'
   group by s.emp_id
   order by count(r.id), random()
   limit 1;
  return v;
end;
$$;
revoke all on function public.ins_pick_assignee(text, text, text) from public, anon, authenticated;

-- ---------- 5) กรมธรรม์ที่ยังมีผล — คืนแบรนด์มาด้วย ----------
drop function if exists public.ins_active_policies();
create or replace function public.ins_active_policies()
returns table (emp_id text, plate text, vin text, expire_on date, brand text)
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
    select a.emp_id, a.plate, a.vin, a.expire_on, a.brand
      from public.ins_active_policy a
     where a.expire_on >= public.ins_today()
     order by a.emp_id, a.expire_on;
end;
$$;
revoke all on function public.ins_active_policies()  from public, anon;
grant execute on function public.ins_active_policies() to authenticated;

-- ---------- 6) ชื่อเจ้าหน้าที่: ทีมประกันเป็นพนักงานโตโยต้า ----------
--   ตอนนี้ทำเนียบมี 2 แบรนด์ที่รหัสซ้ำกันได้ → join เฉย ๆ จะได้ 2 แถว/ชื่อผิด
--   แก้ทุกฟังก์ชันที่ join แบบเดิมด้วยการเติมเงื่อนไขแบรนด์เข้าไปในนิยามเดิม
do $f$
declare
  fn  text;
  d   text;
  old text := 'employees e on e.emp_id = s.emp_id';
  new text := 'employees e on e.emp_id = s.emp_id and e.brand = ''toyota''';
begin
  foreach fn in array array['public.ins_whoami()', 'public.ins_agents()',
                            'public.ins_viewer_agents()',
                            'public.ins_line_bind_srv(text, text)'] loop
    if to_regprocedure(fn) is null then
      raise notice 'ไม่พบฟังก์ชัน % — ข้าม', fn;
      continue;
    end if;
    d := pg_get_functiondef(fn::regprocedure);
    if position(old in d) = 0 then
      raise notice '% ไม่มี join ทำเนียบแบบเดิม — ข้าม', fn;
    elsif position('e.brand' in d) > 0 then
      raise notice '% เติมแบรนด์ไว้แล้ว — ข้าม', fn;
    else
      execute replace(d, old, new);
    end if;
  end loop;
end $f$;

-- ---------- 7) ข้อความ LINE: บอกแบรนด์ + นับรถแยกแบรนด์ ----------
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
  return p_head
    || case when v_br = 'hino' then ' · ฮีโน่' else '' end
    || E'\nเลขที่: ' || p_req.no
    || E'\nแบบคำขอ: ' || case when v_refer then 'แนะนำลูกค้าทั่วไป' else 'พนักงานทำประกันเอง' end
    || E'\n' || case when v_refer then 'ลูกค้า: ' else 'ผู้ทำประกัน: ' end || regexp_replace(p_req.insured_name, '\s+', ' ', 'g')
    || E'\nโทร: ' || coalesce(nullif(p_req.phone_mobile, ''), '-')
    || E'\n' || case when v_refer then 'ผู้แนะนำ: ' else 'พนักงาน: ' end
    || regexp_replace(p_req.emp_name, '\s+', ' ', 'g')
    || case when coalesce(p_req.emp_dept, '') <> '' then ' (' || p_req.emp_dept || ')' else '' end
    || case when v_br = 'hino' then ' · ฮีโน่' else '' end
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

-- ---------- 8) ins_submit: รับแบรนด์จากฟอร์ม ----------
do $f$
declare
  d   text;
  n   int;
  v_a text;
  -- คู่ (หาเจอ 1 จุด → แทนที่)
  a1  text := '  v_emp_id    text;';
  a1n text := '  v_emp_id    text;' || chr(10) || '  v_brand     text;';
  a2  text := '  v_kind := coalesce(payload->>''kind'', ''self'');';
  a2n text := '  v_brand := public.ins_brand(payload->>''brand'');' || chr(10)
              || '  v_kind := coalesce(payload->>''kind'', ''self'');';
  a3  text := 'where e.emp_id = v_emp_id and e.active is true;';
  a3n text := 'where e.emp_id = v_emp_id and e.brand = v_brand and e.active is true;';
  a4  text := 'insert into public.ins_seq (ym, n) values (v_ym, 1)';
  a4n text := 'insert into public.ins_seq (ym, n) values (case when v_brand = ''hino'' then ''H'' || v_ym else v_ym end, 1)';
  a5  text := 'v_no := ''INS-'' || v_ym';
  a5n text := 'v_no := case when v_brand = ''hino'' then ''HIN-'' else ''INS-'' end || v_ym';
  a6  text := 'public.ins_pick_assignee(case when v_verified then v_emp_id end, v_kind)';
  a6n text := 'public.ins_pick_assignee(case when v_verified then v_emp_id end, v_kind, v_brand)';
  a7  text := 'public.ins_car_gate(v_emp_id, payload->>''carPlate'', payload->>''carVin'')';
  a7n text := 'public.ins_car_gate(v_emp_id, payload->>''carPlate'', payload->>''carVin'', v_brand)';
  a8  text := '    no, kind, emp_id, emp_name,';
  a8n text := '    no, brand, kind, emp_id, emp_name,';
  a9  text := '    v_no, v_kind, v_emp_id, v_name, v_dept,';
  a9n text := '    v_no, v_brand, v_kind, v_emp_id, v_name, v_dept,';
begin
  d := pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure);
  if position('v_brand' in d) > 0 then
    raise notice 'ins_submit รับแบรนด์อยู่แล้ว — ข้าม';
  else
    if position('ins_car_gate' in d) = 0 then
      raise exception 'ins_submit ยังไม่ได้รัน migrate-2026-09-21-car-lock.sql — หยุด';
    end if;
    foreach v_a in array array[a1, a2, a3, a4, a5, a6, a7, a8, a9] loop
      n := (length(d) - length(replace(d, v_a, ''))) / length(v_a);
      if n <> 1 then raise exception 'ins_submit: หา "%" เจอ % จุด (ต้อง 1)', left(v_a, 50), n; end if;
    end loop;
    d := replace(d, a1, a1n);
    d := replace(d, a2, a2n);
    d := replace(d, a3, a3n);
    d := replace(d, a4, a4n);
    d := replace(d, a5, a5n);
    d := replace(d, a6, a6n);
    d := replace(d, a7, a7n);
    d := replace(d, a8, a8n);
    d := replace(d, a9, a9n);
    execute d;                                          -- create or replace → สิทธิ์เดิมยังอยู่ครบ
  end if;
end $f$;

-- ---------- 9) วิวสำหรับหน้าเจ้าหน้าที่ (เพิ่ม brand) ----------
--   ⚠️ ต้อง drop ก่อน: create or replace view "เพิ่มคอลัมน์ต่อท้าย" ได้อย่างเดียว
--      แทรก brand ไว้กลาง ๆ แบบนี้จะได้ ERROR 42P16 cannot change name of view column
--      (ไม่มีอะไรอ้างถึงวิวนี้ — หน้าเว็บเรียกผ่าน PostgREST · สิทธิ์ให้ใหม่ด้านล่างแล้ว)
drop view if exists public.ins_requests_view;
create view public.ins_requests_view
with (security_invoker = true) as
  select id, no, kind, brand,
         emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
         insured_name, addr, moo, road, tambon, amphoe, province,
         phone_home, phone_mobile, relation, relation_note,
         car_brand, car_model, car_plate, car_year, covers,
         doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note,
         note, status, status_note, created_at, updated_at,
         assigned_to, assigned_at,
         id_card, zipcode, occupation, workplace, income,
         consent_at, consent_version, birth_date,
         insured_title,
         quote_insurer, quote_type,
         quote_net, quote_gross, quote_disc,
         quote_act_net, quote_act_gross, quote_act_disc,
         quote_total, quote_note, quote_at, quote_by,
         car_province, car_vin,
         quote_start, quote_act_start, quote_end, quote_act_end,
         add_reason
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;

-- ---------- 10) สิทธิ์ ----------
-- ins_brand ถูกเรียกจากในฟังก์ชัน security definer เท่านั้น (รันด้วยสิทธิ์เจ้าของ) → ไม่ต้องเปิดให้ใคร
revoke all on function public.ins_brand(text)                          from public, anon, authenticated;
revoke all on function public.ins_lookup_emp(text, text)               from public;
grant execute on function public.ins_lookup_emp(text, text)            to anon, authenticated;
revoke all on function public.ins_car_gate(text, text, text, text)     from public;
grant execute on function public.ins_car_gate(text, text, text, text)  to anon, authenticated;
revoke all on function public.ins_car_others(text, text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.ins_car2_check(text, text, text, text)   from public, anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้)
--   select (select count(*) from information_schema.columns
--            where table_name = 'ins_requests_view' and column_name = 'brand')            as view_brand,
--          position('v_brand' in pg_get_functiondef('public.ins_submit(jsonb)'::regprocedure)) > 0
--                                                                                         as submit_ok,
--          public.ins_car_gate('00000000', '', '', 'hino')->>'state'                      as gate_hino,
--          (select count(*) from public.employees where brand = 'hino')                   as hino_emp;
--   -- ต้องได้ view_brand = 1 · submit_ok = true · gate_hino = first · hino_emp = 0 (ยังไม่นำเข้า)
-- ============================================================================
