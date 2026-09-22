-- ============================================================================
-- ฟังก์ชันต่ออายุกรมธรรม์ (2026-09-22)
--
--   ใช้ข้อมูลที่มีอยู่แล้วทั้งหมด: ins_active_policy (วันหมดอายุ) + employees (ชื่อ)
--   + ins_emp_addr (ที่อยู่/เบอร์) + ins_emp_owner & ins_requests (ผู้ดูแลประจำตัว)
--
--   ของใหม่ในไฟล์นี้
--     1) ins_emp_addr.phone_mobile      — เบอร์โทร (ผู้ใช้สั่งเก็บ เพื่อทำรายการโทรตามงาน)
--     2) ins_addr_of()                  — เพิ่มเบอร์ในผลลัพธ์ (เจ้าหน้าที่เท่านั้น)
--     3) ins_renewals(p_days)           — รายการกรมธรรม์ใกล้หมดอายุ + ผู้ดูแล + มีใบค้างไหม
--     4) ins_renew_start(...)           — สร้างใบต่ออายุจากกรมธรรม์ใบนั้น เติมข้อมูลที่มีให้
--
--   🔒 ins_addr_pub() (ตัวที่ฟอร์มสาธารณะเรียก) "ไม่ถูกแตะ" — ยังคืนแค่ 7 ช่องที่อยู่
--      เบอร์โทรเห็นได้เฉพาะเจ้าหน้าที่ที่ล็อกอิน ไม่หลุดไปหน้าเว็บที่ไม่มีล็อกอิน
--
-- ✅ รันไฟล์นี้ไฟล์เดียวพอ · รันซ้ำได้ (idempotent)
-- ⚠️ ต้องรันหลัง migrate-2026-09-22-emp-addr.sql
-- ============================================================================

begin;

-- ---------- 1) เบอร์โทรในตารางที่อยู่ ----------
alter table public.ins_emp_addr add column if not exists phone_mobile text not null default '';
comment on column public.ins_emp_addr.phone_mobile is
  'เบอร์มือถือจาก Excel ฝ่ายประกัน — เห็นได้เฉพาะเจ้าหน้าที่ (ins_addr_of/ins_renewals) ไม่อยู่ใน ins_addr_pub';

-- ---------- 2) เจ้าหน้าที่อ่านที่อยู่ + เบอร์ ----------
drop function if exists public.ins_addr_of(text, text);
create or replace function public.ins_addr_of(p_emp text, p_brand text default 'toyota')
returns table (addr text, moo text, road text, tambon text, amphoe text,
               province text, zipcode text, phone_mobile text)
language plpgsql stable security definer
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
    select a.addr, a.moo, a.road, a.tambon, a.amphoe, a.province, a.zipcode, a.phone_mobile
      from public.ins_emp_addr a
     where a.emp_id = v_id and a.brand = public.ins_brand(p_brand);
end;
$$;
revoke all on function public.ins_addr_of(text, text) from public, anon;
grant execute on function public.ins_addr_of(text, text) to authenticated;

-- ---------- 3) รายการกรมธรรม์ใกล้หมดอายุ ----------
--   p_days = มองไปข้างหน้ากี่วัน (ค่าเริ่ม 90) · ใบที่เลยกำหนดแล้วติดมาด้วยเสมอ (days_left ติดลบ)
--   ผู้ดูแลประจำตัว = ผู้ดูแลใบล่าสุดของพนักงานคนนั้น ถ้าไม่มีใช้ mapping จาก Excel (ins_emp_owner)
--   🔑 เจ้าหน้าที่ทั่วไปเห็นเฉพาะของตัวเอง + ที่ยังไม่มีผู้ดูแล · บัญชีกลางเห็นทั้งหมด
create or replace function public.ins_renewals(p_days int default 90)
returns table (
  brand text, emp_id text, emp_name text, plate text, vin text,
  expire_on date, days_left int, phone_mobile text,
  agent_emp_id text, agent_name text, open_no text, open_status text
)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  return query
  with pol as (
    select a.brand, a.emp_id, a.plate, a.vin, a.expire_on
      from public.ins_active_policy a
     where a.expire_on <= public.ins_today() + greatest(coalesce(p_days, 90), 0)
  ),
  own as (
    select p.brand, p.emp_id,
           coalesce(
             (select r.assigned_to from public.ins_requests r
               where r.emp_id = p.emp_id and r.brand = p.brand and r.kind = 'self'
                 and r.status <> 'cancelled' and r.assigned_to is not null
               order by r.created_at desc limit 1),
             (select o.agent_emp_id from public.ins_emp_owner o
               where o.emp_id = p.emp_id and o.brand = p.brand)
           ) as agent
      from (select distinct brand, emp_id from pol) p
  )
  select p.brand, p.emp_id,
         coalesce(e.name, p.emp_id) as emp_name,
         p.plate, p.vin, p.expire_on,
         (p.expire_on - public.ins_today())::int as days_left,
         coalesce(ad.phone_mobile, '') as phone_mobile,
         w.agent as agent_emp_id,
         coalesce(ae.name, nullif(split_part(s.note, ' · ', 1), ''), w.agent) as agent_name,
         q.no as open_no, q.status as open_status
    from pol p
    left join own w         on w.brand = p.brand and w.emp_id = p.emp_id
    left join public.employees e    on e.emp_id = p.emp_id and e.brand = p.brand
    left join public.ins_emp_addr ad on ad.emp_id = p.emp_id and ad.brand = p.brand
    left join public.ins_staff s    on s.emp_id = w.agent
    left join public.employees ae   on ae.emp_id = w.agent and ae.brand = 'toyota'
    left join lateral (
      select r.no, r.status
        from public.ins_requests r
       where r.brand = p.brand and r.emp_id = p.emp_id and r.kind = 'self'
         and r.status not in ('done','cancelled')
         and ((public.ins_plate_key(p.plate) <> ''
               and public.ins_plate_key(r.car_plate) = public.ins_plate_key(p.plate))
           or (public.ins_vin_key(p.vin) <> ''
               and public.ins_vin_key(r.car_vin) = public.ins_vin_key(p.vin)))
       order by r.created_at desc limit 1
    ) q on true
   where public.is_ins_admin() or w.agent is null or w.agent = public.ins_my_emp()
   order by p.expire_on, p.emp_id;
end;
$$;
revoke all on function public.ins_renewals(int) from public, anon;
grant execute on function public.ins_renewals(int) to authenticated;

-- ---------- 4) สร้างใบต่ออายุจากกรมธรรม์ ----------
--   เติมให้จากข้อมูลที่มี: ชื่อ/แผนกจากทำเนียบ · ที่อยู่+เบอร์จาก ins_emp_addr · รถจากกรมธรรม์
--   ที่ยังต้องกรอกเอง: เลขบัตรประชาชน วันเกิด อาชีพ ที่ทำงาน รายได้ (ไม่มีในระบบ)
--   🔑 add_reason = 'renew' · relation = 'self' · ผู้ดูแลใช้กติกาเดิม (ins_pick_assignee)
--   🔑 กันสร้างซ้ำ: มีใบของรถคันนี้ที่ยังไม่ปิด/ไม่ยกเลิก = ไม่สร้างใหม่
create or replace function public.ins_renew_start(p_brand text, p_emp text, p_plate text, p_vin text default '')
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_br    text := public.ins_brand(p_brand);
  v_id    text := regexp_replace(coalesce(p_emp, ''), '[^0-9A-Za-z_-]', '', 'g');
  v_pk    text := public.ins_plate_key(p_plate);
  v_vk    text := public.ins_vin_key(p_vin);
  v_pol   record;
  v_emp   record;
  v_ad    record;
  v_dup   text;
  v_agent text;
  v_ym    text;
  v_n     integer;
  v_no    text;
  v_token text;
  v_new   uuid;
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  if v_id = '' or (v_pk = '' and v_vk = '') then
    raise exception 'ต้องระบุรหัสพนักงานและทะเบียนรถ' using errcode = 'P0001';
  end if;

  select a.plate, a.vin, a.expire_on into v_pol
    from public.ins_active_policy a
   where a.brand = v_br and a.emp_id = v_id
     and ((v_pk <> '' and public.ins_plate_key(a.plate) = v_pk)
       or (v_vk <> '' and public.ins_vin_key(a.vin) = v_vk))
   order by a.expire_on limit 1;
  if not found then
    raise exception 'ไม่พบกรมธรรม์ของรถคันนี้ในระบบ' using errcode = 'P0001';
  end if;

  select r.no into v_dup
    from public.ins_requests r
   where r.brand = v_br and r.emp_id = v_id and r.kind = 'self'
     and r.status not in ('done','cancelled')
     and ((v_pk <> '' and public.ins_plate_key(r.car_plate) = v_pk)
       or (v_vk <> '' and public.ins_vin_key(r.car_vin) = v_vk))
   limit 1;
  if v_dup is not null then
    raise exception 'มีใบของรถคันนี้อยู่ในระบบแล้ว (%) — เปิดใบเดิมแทนการสร้างใหม่', v_dup
      using errcode = 'P0001';
  end if;

  select e.name, e.dept into v_emp from public.employees e
   where e.emp_id = v_id and e.brand = v_br and e.active is true;
  if not found then
    raise exception 'ไม่พบรหัสพนักงานนี้ในทำเนียบ' using errcode = 'P0001';
  end if;

  select a.addr, a.moo, a.road, a.tambon, a.amphoe, a.province, a.zipcode, a.phone_mobile
    into v_ad
    from public.ins_emp_addr a
   where a.emp_id = v_id and a.brand = v_br;

  v_agent := public.ins_pick_assignee(v_id, 'self', v_br);

  v_ym := to_char(now() at time zone 'Asia/Bangkok', 'YYMM');
  insert into public.ins_seq (ym, n)
       values (case when v_br = 'hino' then 'H' || v_ym else v_ym end, 1)
    on conflict (ym) do update set n = public.ins_seq.n + 1
    returning n into v_n;
  v_no := case when v_br = 'hino' then 'HIN-' else 'INS-' end
          || v_ym || '-' || lpad(v_n::text, greatest(3, length(v_n::text)), '0');
  v_token := encode(gen_random_bytes(16), 'hex');

  insert into public.ins_requests (
    no, brand, kind, emp_id, emp_name, emp_dept, emp_verified,
    insured_name, addr, moo, road, tambon, amphoe, province, zipcode, phone_mobile,
    relation, car_plate, car_vin, covers, note, add_reason,
    upload_token, assigned_to, assigned_at, status
  ) values (
    v_no, v_br, 'self', v_id, v_emp.name, coalesce(v_emp.dept, ''), true,
    v_emp.name,
    coalesce(v_ad.addr, ''), coalesce(v_ad.moo, ''), coalesce(v_ad.road, ''),
    coalesce(v_ad.tambon, ''), coalesce(v_ad.amphoe, ''), coalesce(v_ad.province, ''),
    coalesce(v_ad.zipcode, ''), coalesce(v_ad.phone_mobile, ''),
    'self', coalesce(v_pol.plate, ''), coalesce(v_pol.vin, ''), '{}',
    'สร้างจากรายการต่ออายุ — กรมธรรม์เดิมหมดอายุ ' || to_char(v_pol.expire_on, 'DD/MM/YYYY'),
    'renew', v_token, v_agent,
    case when v_agent is not null then now() else null end, 'new'
  ) returning id into v_new;

  return jsonb_build_object('ok', true, 'id', v_new, 'no', v_no,
                            'hasAddr', v_ad.addr is not null and v_ad.addr <> '',
                            'assignee', v_agent);
end;
$$;
revoke all on function public.ins_renew_start(text, text, text, text) from public, anon;
grant execute on function public.ins_renew_start(text, text, text, text) to authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ตรวจหลังรัน (คัดลอกไปรันแยกได้ — ต้องรันในบัญชีเจ้าหน้าที่ ถ้ารันใน SQL Editor จะขึ้นว่าไม่มีสิทธิ์
--   ซึ่งถูกต้อง เพราะ Editor ไม่ใช่บัญชีเจ้าหน้าที่ประกัน)
--
--   select (select count(*) from information_schema.columns
--            where table_name = 'ins_emp_addr' and column_name = 'phone_mobile')   as phone_col,
--          (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--            where n.nspname='public' and p.proname = 'ins_renewals')              as list_fn,
--          (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--            where n.nspname='public' and p.proname = 'ins_renew_start')           as start_fn;
--   -- ต้องได้ 1 ทุกช่อง
--
--   -- ดูจำนวนกรมธรรม์ที่จะขึ้นในรายการ (ไม่ผ่านฟังก์ชัน จึงรันใน Editor ได้)
--   select case when expire_on < public.ins_today() then 'เลยกำหนด'
--               when expire_on <= public.ins_today() + 30 then 'ภายใน 30 วัน'
--               when expire_on <= public.ins_today() + 60 then '31-60 วัน'
--               else '61-90 วัน' end as ช่วง, count(*)
--     from public.ins_active_policy
--    where expire_on <= public.ins_today() + 90
--    group by 1 order by 1;
-- ============================================================================
