-- =====================================================================
--  migrate 2026-09-14 (3) : สุ่มเจ้าหน้าที่ดูแลลูกค้าให้เท่า ๆ กัน
--
--  กติกา (ผู้ใช้เลือก):
--  - แจกอัตโนมัติทันทีที่ลูกค้าส่งคำขอ (ใน ins_submit)
--  - เท่ากันแบบ "นับสะสมตั้งแต่เริ่มใช้" — ใครมีใบน้อยสุดได้ก่อน เสมอกันค่อยสุ่ม
--    (ไม่นับใบที่ยกเลิก)
--  - เจ้าหน้าที่ (role = agent) เห็นเฉพาะใบที่ตัวเองดูแล
--  - บัญชีกลาง (role = admin เช่น insurance@toyotakan.co.th) เห็นทุกใบ + เปลี่ยนผู้ดูแลได้
--    และไม่ถูกนับเข้ากองแจกงาน
--
--  วิธีใช้: SQL Editor → วางทั้งไฟล์ → Run (รันซ้ำได้)
--  ⚠️ push หน้าเว็บ staff.html รุ่นใหม่ก่อน/พร้อมกัน
-- =====================================================================

-- ---------- 1) คอลัมน์ ----------
alter table public.ins_requests add column if not exists assigned_to text;          -- emp_id ใน ins_staff
alter table public.ins_requests add column if not exists assigned_at timestamptz;
create index if not exists ins_requests_assigned_idx on public.ins_requests (assigned_to);

alter table public.ins_staff add column if not exists role text not null default 'agent';
alter table public.ins_staff drop constraint if exists ins_staff_role_chk;
alter table public.ins_staff add constraint ins_staff_role_chk check (role in ('agent','admin'));
-- บัญชีกลางที่ใช้อีเมลเต็ม = ผู้ดูแล ไม่อยู่ในกองแจกงาน
update public.ins_staff set role = 'admin' where emp_id like '%@%';

-- ---------- 2) ตัวช่วยดูว่าผู้ใช้ที่ล็อกอินอยู่เป็นใคร ----------
create or replace function public.ins_my_emp()
returns text
language sql stable security definer
set search_path = public
as $$
  select s.emp_id from public.ins_staff s
   where s.active
     and lower(coalesce(auth.jwt()->>'email', '')) in (lower(s.emp_id) || '@staff.toyotakan', lower(s.emp_id))
   limit 1;
$$;

create or replace function public.is_ins_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ins_staff s
     where s.active and s.role = 'admin'
       and lower(coalesce(auth.jwt()->>'email', '')) in (lower(s.emp_id) || '@staff.toyotakan', lower(s.emp_id))
  );
$$;

-- ใบนี้ผู้ใช้ที่ล็อกอินอยู่เห็นได้ไหม
create or replace function public.ins_can_see(p_assigned text)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select public.is_ins_admin()
      or (p_assigned is not null and p_assigned = public.ins_my_emp());
$$;

-- ให้หน้าเว็บรู้ว่าตัวเองเป็นใคร (ชื่อ + บทบาท)
create or replace function public.ins_whoami()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object(
           'empId', s.emp_id,
           'role',  s.role,
           'name',  coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id))
    from public.ins_staff s
    left join public.employees e on e.emp_id = s.emp_id
   where s.emp_id = public.ins_my_emp();
$$;

-- ---------- 3) ตัวเลือกผู้ดูแล ----------
-- 🔑 ล็อกกันยื่นพร้อมกัน 2 ใบแล้วได้คนเดียวกัน (ล็อกค้างจนจบทรานแซกชันของ ins_submit)
create or replace function public.ins_pick_assignee()
returns text
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v text;
begin
  perform pg_advisory_xact_lock(hashtext('ins_pick_assignee'));
  select s.emp_id into v
    from public.ins_staff s
    left join public.ins_requests r
           on r.assigned_to = s.emp_id and r.status <> 'cancelled'
   where s.active and s.role = 'agent'
   group by s.emp_id
   order by count(r.id), random()
   limit 1;
  return v;                                  -- ไม่มีเจ้าหน้าที่เลย = null (บัญชีกลางยังเห็น)
end;
$$;

-- ---------- 4) ยื่นคำขอ: ใส่ผู้ดูแลตอนสร้างใบ ----------
create or replace function public.ins_submit(payload jsonb)
returns jsonb
language plpgsql
security definer
-- ต้องมี extensions ใน search_path ด้วย เพราะเรียก gen_random_bytes (pgcrypto)
set search_path = public, extensions
as $$
declare
  v_ip        text := coalesce(current_setting('request.headers', true)::json->>'x-forwarded-for', '');
  v_kind      text;
  v_emp_id    text;
  v_typed     text;
  v_emp       record;
  v_name      text;
  v_dept      text;
  v_verified  boolean := false;
  v_typedkeep text := null;
  v_insured   text;
  v_mobile    text;
  v_covers    text[];
  v_relation  text;
  v_ym        text;
  v_n         integer;
  v_no        text;
  v_token     text;
  v_id        uuid;
  v_recent    integer;
  v_assignee  text;
  c_title     text := '^\s*(ว่าที่\s*ร\.?ต\.?(อ|ท|ญ)?\.?|ว่าที่\s*ร\.?อ\.?|นางสาว|น\.ส\.|นาง|นาย|ดร\.|ผศ\.|รศ\.|ศ\.|คุณ)\s*';
begin
  select count(*) into v_recent from public.ins_submit_log
   where ip = v_ip and created_at > now() - interval '10 minutes';
  if v_recent >= 40 then
    raise exception 'ยื่นคำขอถี่เกินไป กรุณารอสักครู่แล้วลองใหม่' using errcode = 'P0001';
  end if;

  if coalesce(payload->>'hp', '') <> '' then
    raise exception 'ไม่สามารถรับคำขอนี้ได้' using errcode = 'P0001';
  end if;

  v_kind := coalesce(payload->>'kind', 'self');
  if v_kind not in ('self','refer') then v_kind := 'self'; end if;

  v_emp_id := regexp_replace(coalesce(payload->>'empId', ''), '[^0-9A-Za-z_-]', '', 'g');
  v_typed  := btrim(regexp_replace(coalesce(payload->>'empName', ''), c_title, ''));
  if v_emp_id = '' then
    raise exception 'กรุณากรอกรหัสพนักงานผู้แนะนำ' using errcode = 'P0001';
  end if;
  select e.name, e.dept into v_emp from public.employees e
   where e.emp_id = v_emp_id and e.active is true;
  if found then
    v_verified := true;
    v_name := v_emp.name;
    v_dept := coalesce(nullif(v_emp.dept, ''), left(btrim(coalesce(payload->>'empDept', '')), 60));
    if v_typed <> '' and v_typed <> v_emp.name then v_typedkeep := v_typed; end if;
  else
    if v_typed = '' then
      raise exception 'กรุณากรอกชื่อ-นามสกุลพนักงาน' using errcode = 'P0001';
    end if;
    v_name := v_typed;
    v_dept := left(btrim(coalesce(payload->>'empDept', '')), 60);
  end if;

  v_insured := btrim(regexp_replace(coalesce(payload->>'insuredName', ''), c_title, ''));
  if v_insured = '' then
    raise exception 'กรุณากรอกชื่อผู้ทำประกันภัย' using errcode = 'P0001';
  end if;
  v_mobile := regexp_replace(coalesce(payload->>'phoneMobile', ''), '[^0-9+ -]', '', 'g');
  if length(regexp_replace(v_mobile, '[^0-9]', '', 'g')) < 9 then
    raise exception 'กรุณากรอกเบอร์โทรศัพท์มือถือให้ครบ' using errcode = 'P0001';
  end if;

  if btrim(coalesce(payload->>'addr', '')) = '' then
    raise exception 'กรุณากรอกบ้านเลขที่' using errcode = 'P0001';
  end if;
  if btrim(coalesce(payload->>'tambon', '')) = '' then
    raise exception 'กรุณากรอกตำบล / แขวง' using errcode = 'P0001';
  end if;
  if btrim(coalesce(payload->>'amphoe', '')) = '' then
    raise exception 'กรุณากรอกอำเภอ / เขต' using errcode = 'P0001';
  end if;
  if btrim(coalesce(payload->>'province', '')) = '' then
    raise exception 'กรุณากรอกจังหวัด' using errcode = 'P0001';
  end if;

  select array_agg(distinct c) into v_covers
    from jsonb_array_elements_text(coalesce(payload->'covers', '[]'::jsonb)) c
   where c in ('type1','type2plus','type3','type3plus','act');
  if v_covers is null then v_covers := '{}'; end if;

  v_relation := coalesce(payload->>'relation', 'self');
  if v_relation not in ('self','father','mother','husband','wife','child','other') then
    v_relation := case when v_kind = 'refer' then 'other' else 'self' end;
  end if;
  if v_kind = 'refer' then v_relation := 'other'; end if;

  v_ym := to_char(now() at time zone 'Asia/Bangkok', 'YYMM');
  insert into public.ins_seq (ym, n) values (v_ym, 1)
    on conflict (ym) do update set n = public.ins_seq.n + 1
    returning n into v_n;
  v_no := 'INS-' || v_ym || '-' || lpad(v_n::text, 3, '0');

  v_token := encode(gen_random_bytes(16), 'hex');

  -- ผู้ดูแล: ใครมีใบสะสมน้อยสุดได้ก่อน เสมอกันสุ่ม
  v_assignee := public.ins_pick_assignee();

  insert into public.ins_requests (
    no, kind, emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
    insured_name, addr, moo, road, tambon, amphoe, province, phone_home, phone_mobile,
    relation, relation_note, car_brand, car_model, car_plate, car_year, covers,
    doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note, note,
    upload_token, submit_ip, assigned_to, assigned_at
  ) values (
    v_no, v_kind, v_emp_id, v_name, v_dept,
    left(coalesce(payload->>'empBranch', ''), 60), v_verified, v_typedkeep,
    left(v_insured, 120),
    left(coalesce(payload->>'addr', ''), 80),
    left(coalesce(payload->>'moo', ''), 20),
    left(coalesce(payload->>'road', ''), 60),
    left(coalesce(payload->>'tambon', ''), 60),
    left(coalesce(payload->>'amphoe', ''), 60),
    left(coalesce(payload->>'province', ''), 60),
    left(regexp_replace(coalesce(payload->>'phoneHome', ''), '[^0-9+ -]', '', 'g'), 20),
    left(v_mobile, 20),
    v_relation,
    case when v_relation = 'other' then left(coalesce(payload->>'relationNote', ''), 60) else '' end,
    left(coalesce(payload->>'carBrand', ''), 60),
    left(coalesce(payload->>'carModel', ''), 60),
    left(coalesce(payload->>'carPlate', ''), 30),
    left(regexp_replace(coalesce(payload->>'carYear', ''), '[^0-9]', '', 'g'), 10),
    v_covers,
    coalesce((payload->>'docCarReg')::boolean, false),
    coalesce((payload->>'docIdCard')::boolean, false),
    coalesce((payload->>'docOldPolicy')::boolean, false),
    coalesce((payload->>'docRelDoc')::boolean, false),
    case when coalesce((payload->>'docRelDoc')::boolean, false)
         then left(coalesce(payload->>'docRelDocNote', ''), 60) else '' end,
    left(coalesce(payload->>'note', ''), 500),
    v_token, v_ip, v_assignee, case when v_assignee is null then null else now() end
  ) returning id into v_id;

  insert into public.ins_submit_log (ip) values (v_ip);

  -- 🔒 ไม่คืนชื่อผู้ดูแลให้ฟอร์มสาธารณะ
  return jsonb_build_object(
    'id', v_id, 'no', v_no, 'uploadToken', v_token,
    'empName', v_name, 'empDept', v_dept, 'empVerified', v_verified,
    'insuredName', v_insured, 'phoneMobile', v_mobile, 'covers', to_jsonb(v_covers),
    'kind', v_kind,
    'car', jsonb_build_object('brand', coalesce(payload->>'carBrand',''),
                              'model', coalesce(payload->>'carModel',''),
                              'plate', coalesce(payload->>'carPlate',''))
  );
end;
$$;

-- ---------- 5) บัญชีกลาง: เปลี่ยนผู้ดูแล + ดูยอดแต่ละคน ----------
create or replace function public.ins_assign(p_req uuid, p_emp text)
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_ins_admin() then
    raise exception 'เปลี่ยนผู้ดูแลได้เฉพาะบัญชีผู้ดูแล' using errcode = 'P0001';
  end if;
  if p_emp is not null and not exists (
       select 1 from public.ins_staff where emp_id = p_emp and active and role = 'agent') then
    raise exception 'ไม่พบเจ้าหน้าที่คนนี้' using errcode = 'P0001';
  end if;
  update public.ins_requests
     set assigned_to = p_emp,
         assigned_at = case when p_emp is null then null else now() end,
         updated_at = now()
   where id = p_req;
  if not found then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.ins_agents()
returns table (emp_id text, name text, active_count bigint, total_count bigint)
language plpgsql stable security definer
set search_path = public
as $$
begin
  if not public.is_ins_admin() then
    raise exception 'เฉพาะบัญชีผู้ดูแล' using errcode = 'P0001';
  end if;
  return query
    select s.emp_id,
           coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id),
           count(r.id) filter (where r.status <> 'cancelled'),
           count(r.id)
      from public.ins_staff s
      left join public.employees e on e.emp_id = s.emp_id
      left join public.ins_requests r on r.assigned_to = s.emp_id
     where s.active and s.role = 'agent'
     group by s.emp_id, e.name, s.note
     order by s.emp_id;
end;
$$;

-- เจ้าหน้าที่เปลี่ยนสถานะได้เฉพาะใบของตัวเอง (security definer ข้าม RLS → ต้องเช็คเอง)
create or replace function public.ins_set_status(p_req uuid, p_status text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_ins_staff() then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  if p_status not in ('new','contacted','quoted','done','cancelled') then
    raise exception 'สถานะไม่ถูกต้อง' using errcode = 'P0001';
  end if;
  update public.ins_requests
     set status = p_status, status_note = left(coalesce(p_note,''), 300), updated_at = now()
   where id = p_req and public.ins_can_see(assigned_to);
  if not found then
    raise exception 'ไม่พบใบคำขอ' using errcode = 'P0001';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.ins_my_emp()          from public;
revoke all on function public.is_ins_admin()        from public;
revoke all on function public.ins_can_see(text)     from public;
revoke all on function public.ins_whoami()          from public;
revoke all on function public.ins_pick_assignee()   from public;   -- เรียกได้เฉพาะภายใน ins_submit
revoke all on function public.ins_assign(uuid, text) from public;
revoke all on function public.ins_agents()          from public;
grant execute on function public.ins_my_emp()           to authenticated;
grant execute on function public.is_ins_admin()         to authenticated;
grant execute on function public.ins_can_see(text)      to authenticated;
grant execute on function public.ins_whoami()           to authenticated;
grant execute on function public.ins_assign(uuid, text) to authenticated;
grant execute on function public.ins_agents()           to authenticated;

-- ---------- 6) RLS: เจ้าหน้าที่เห็นเฉพาะใบของตัวเอง ----------
drop policy if exists staff_read_requests on public.ins_requests;
create policy staff_read_requests on public.ins_requests
  for select to authenticated using (public.ins_can_see(assigned_to));

drop policy if exists staff_update_requests on public.ins_requests;
create policy staff_update_requests on public.ins_requests
  for update to authenticated
  using (public.ins_can_see(assigned_to)) with check (public.ins_can_see(assigned_to));

drop policy if exists staff_delete_requests on public.ins_requests;
create policy staff_delete_requests on public.ins_requests
  for delete to authenticated using (public.is_ins_admin());

-- ไฟล์แนบ: เห็นได้เมื่อเห็นใบนั้น (subquery ถูก RLS ของ ins_requests กรองให้อีกชั้น)
drop policy if exists staff_read_files on public.ins_files;
create policy staff_read_files on public.ins_files
  for select to authenticated
  using (exists (select 1 from public.ins_requests r where r.id = req_id));

drop policy if exists staff_delete_files on public.ins_files;
create policy staff_delete_files on public.ins_files
  for delete to authenticated using (public.is_ins_admin());

drop policy if exists ins_files_staff_read on storage.objects;
create policy ins_files_staff_read on storage.objects
  for select to authenticated
  using (bucket_id = 'ins-files'
         and exists (select 1 from public.ins_requests r
                      where r.id::text = (storage.foldername(name))[1]));

drop policy if exists ins_files_staff_delete on storage.objects;
create policy ins_files_staff_delete on storage.objects
  for delete to authenticated using (bucket_id = 'ins-files' and public.is_ins_admin());

-- ---------- 7) view: เพิ่มคอลัมน์ผู้ดูแล (ต่อท้าย) ----------
create or replace view public.ins_requests_view
with (security_invoker = true) as
  select id, no, kind,
         emp_id, emp_name, emp_dept, emp_branch, emp_verified, emp_typed_name,
         insured_name, addr, moo, road, tambon, amphoe, province,
         phone_home, phone_mobile, relation, relation_note,
         car_brand, car_model, car_plate, car_year, covers,
         doc_car_reg, doc_id_card, doc_old_policy, doc_rel_doc, doc_rel_note,
         note, status, status_note, created_at, updated_at,
         assigned_to, assigned_at
    from public.ins_requests;
grant select on public.ins_requests_view to authenticated;
