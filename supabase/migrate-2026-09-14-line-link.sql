-- =====================================================================
--  migrate 2026-09-14 (6) : เจ้าหน้าที่ผูก LINE เองจากหลังบ้าน
--  ใช้ LINE OA "แจ้งเตือนทำประกันภัย" ของตัวเอง (แยกจาก OA ระบบใบสำคัญจ่าย)
--
--  ขั้นตอนของเจ้าหน้าที่:
--  staff.html → ปุ่ม "🔗 แจ้งเตือน LINE" → ได้รหัส 6 หลัก (อายุ 10 นาที ใช้ครั้งเดียว)
--  → แอด LINE OA แล้วพิมพ์รหัสส่งในแชท
--  → LINE ยิง webhook ไป Edge Function `line-webhook` (supabase/functions/line-webhook/index.ts)
--  → ฟังก์ชันตรวจลายเซ็น LINE แล้วเรียก ins_line_bind_srv ด้วย service role → เก็บ line_user_id
--
--  ⚠️ LINE userId ผูกกับ Provider — OA คนละตัว (คนละ Provider) ได้ userId คนละค่า
--     → ล้าง line_user_id ที่เคยดึงมาจาก OA ใบสำคัญจ่ายทิ้งครั้งเดียว (มีธงกันล้างซ้ำ)
--
--  ต้องรัน migrate-2026-09-14-line-notify.sql มาก่อน · รันซ้ำได้
-- =====================================================================
create table if not exists public.ins_settings (
  k text primary key,
  v text not null
);
alter table public.ins_settings enable row level security;      -- ไม่มี policy = อ่านตรงไม่ได้เลย

create table if not exists public.ins_line_codes (
  code       text primary key,
  emp_id     text not null,
  expires_at timestamptz not null
);
alter table public.ins_line_codes enable row level security;

-- ---------- ขอรหัส (เจ้าหน้าที่ที่ล็อกอินอยู่) ----------
create or replace function public.ins_line_code()
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_emp  text := public.ins_my_emp();
  v_code text;
  i      int := 0;
begin
  if v_emp is null then
    raise exception 'บัญชีนี้ไม่มีสิทธิ์ (เฉพาะเจ้าหน้าที่ประกัน)' using errcode = 'P0001';
  end if;
  delete from public.ins_line_codes where expires_at < now() or emp_id = v_emp;   -- มีรหัสใช้ได้ทีละ 1 อัน
  loop
    v_code := lpad((floor(random() * 900000) + 100000)::int::text, 6, '0');
    exit when not exists (select 1 from public.ins_line_codes where code = v_code);
    i := i + 1;
    if i > 20 then raise exception 'ขอรหัสไม่สำเร็จ ลองใหม่อีกครั้ง' using errcode = 'P0001'; end if;
  end loop;
  insert into public.ins_line_codes (code, emp_id, expires_at) values (v_code, v_emp, now() + interval '10 minutes');
  return jsonb_build_object('code', v_code, 'expiresInMin', 10);
end;
$$;

-- ---------- สถานะ / ยกเลิก ----------
create or replace function public.ins_line_status()
returns jsonb
language sql stable security definer
set search_path = public
as $$
  select jsonb_build_object('linked', coalesce(line_user_id, '') <> '')
    from public.ins_staff where emp_id = public.ins_my_emp();
$$;

create or replace function public.ins_line_unlink()
returns jsonb
language plpgsql security definer
set search_path = public
as $$
begin
  update public.ins_staff set line_user_id = null where emp_id = public.ins_my_emp();
  delete from public.ins_line_codes where emp_id = public.ins_my_emp();
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- 1) เลิกใช้ทางเดิม (กุญแจร่วมกับเซิร์ฟเวอร์ในออฟฟิศ) ----------
drop function if exists public.ins_line_bind(text, text, text);
delete from public.ins_settings where k = 'line_bind_hash';

-- ---------- 2) ล้าง LINE ที่มาจาก OA ใบสำคัญจ่าย (ครั้งเดียว) ----------
do $$
begin
  if not exists (select 1 from public.ins_settings where k = 'line_oa') then
    update public.ins_staff set line_user_id = null;
    delete from public.ins_line_codes;
    insert into public.ins_settings (k, v) values ('line_oa', 'insurance');
  end if;
end $$;

-- ---------- 3) ผูก — เรียกได้เฉพาะ service role (Edge Function) ----------
create or replace function public.ins_line_bind_srv(p_code text, p_line_user_id text)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_emp  text;
  v_name text;
begin
  if coalesce(p_line_user_id, '') !~ '^U[0-9a-f]{32}$' then
    return jsonb_build_object('ok', false, 'reason', 'line');
  end if;
  delete from public.ins_line_codes
   where code = btrim(coalesce(p_code, '')) and expires_at >= now()
   returning emp_id into v_emp;                                     -- รหัสใช้ได้ครั้งเดียว
  if v_emp is null then
    return jsonb_build_object('ok', false, 'reason', 'code');
  end if;
  -- LINE เดียวผูกได้บัญชีเดียว (ย้ายจากคนเดิมมาคนใหม่)
  update public.ins_staff set line_user_id = null where line_user_id = p_line_user_id and emp_id <> v_emp;
  update public.ins_staff set line_user_id = p_line_user_id where emp_id = v_emp and active;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'code');
  end if;
  select coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id) into v_name
    from public.ins_staff s left join public.employees e on e.emp_id = s.emp_id
   where s.emp_id = v_emp;
  return jsonb_build_object('ok', true, 'name', regexp_replace(coalesce(v_name, ''), '\s+', ' ', 'g'));
end;
$$;

revoke all on function public.ins_line_bind_srv(text, text) from public, anon, authenticated;
grant execute on function public.ins_line_bind_srv(text, text) to service_role;

revoke all on function public.ins_line_code()                  from public, anon;
revoke all on function public.ins_line_status()                from public, anon;
revoke all on function public.ins_line_unlink()                from public, anon;
grant execute on function public.ins_line_code()   to authenticated;
grant execute on function public.ins_line_status() to authenticated;
grant execute on function public.ins_line_unlink() to authenticated;
