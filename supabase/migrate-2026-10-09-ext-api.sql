-- ============================================================================
-- API ให้ระบบอื่นมาดึงข้อมูลคำขอประกัน (อ่านอย่างเดียว) — 2026-10-09 (ผู้ใช้สั่ง)
--
--   ระบบอื่นเรียก  POST  <SUPABASE_URL>/rest/v1/rpc/ins_ext_requests
--     header  apikey: <anon key>        (กุญแจสาธารณะของโปรเจกต์ — ตัวเดียวกับใน config.js)
--             X-API-Key: <คีย์ของระบบนั้น>   (ออกด้วย ins_api_key_new ด้านล่าง)
--             Content-Type: application/json
--     body    { "p_since": "2026-10-01T00:00:00Z", "p_limit": 200 }      ← ทุกตัวไม่บังคับ
--
--   🔒 ความปลอดภัย
--     - anon ไม่มีสิทธิ์อ่านตารางตรง ๆ เหมือนเดิม — ทางเดียวคือฟังก์ชันนี้ ซึ่งต้องมี X-API-Key ที่ถูกต้อง
--     - เก็บเฉพาะ "แฮช" ของคีย์ (sha256) — คีย์จริงเห็นได้ครั้งเดียวตอนออก ฐานข้อมูลรั่วก็เอาคีย์ไปใช้ไม่ได้
--     - แต่ละคีย์มีขอบเขต: full = ทุกช่อง (รวมเลขบัตร/ที่อยู่/เบอร์/รายได้) · basic = ตัดข้อมูลส่วนบุคคลออก
--     - ไม่ส่ง upload_token (ใช้แนบไฟล์เข้าใบได้) และไม่ส่งลิงก์ไฟล์แนบ — ได้แค่รายชื่อไฟล์
--     - จำกัด 60 ครั้ง/นาทีต่อคีย์ · บันทึกทุกครั้งที่เรียก (ins_api_log) · ปิดคีย์ได้ทันทีด้วย active = false
--     - อ่านอย่างเดียว ไม่มีทางแก้ข้อมูลผ่าน API นี้
--
--   การดึงแบบต่อเนื่อง: ใช้ changed_at (คอลัมน์ใหม่ ขยับทุกครั้งที่แถวถูกแก้) ไม่ใช้ updated_at
--     เพราะ updated_at ไม่ได้ถูกแก้ทุกกรณี และหน้าเจ้าหน้าที่ใช้มันนับ "ค้างกี่วัน" — ไม่อยากให้ความหมายเพี้ยน
--
-- ปลอดภัยต่อการรันซ้ำ
-- ============================================================================

begin;

-- ---------- 1) changed_at: เวลาที่แถวถูกแตะล่าสุด (ทุกกรณี) ----------
alter table public.ins_requests add column if not exists changed_at timestamptz not null default now();
create index if not exists ins_requests_changed_idx on public.ins_requests (changed_at, id);

create or replace function public.ins_touch_changed()
returns trigger language plpgsql as $$
begin
  new.changed_at := clock_timestamp();
  return new;
end $$;
drop trigger if exists ins_requests_touch on public.ins_requests;
create trigger ins_requests_touch
  before insert or update on public.ins_requests
  for each row execute function public.ins_touch_changed();

-- ไฟล์แนบเพิ่ม/ลบ = ใบนั้นเปลี่ยนด้วย
create or replace function public.ins_touch_from_file()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.ins_requests set changed_at = clock_timestamp()
   where id = case when tg_op = 'DELETE' then old.req_id else new.req_id end;
  return null;
end $$;
revoke all on function public.ins_touch_from_file() from public, anon, authenticated;
drop trigger if exists ins_files_touch on public.ins_files;
create trigger ins_files_touch
  after insert or delete on public.ins_files
  for each row execute function public.ins_touch_from_file();

-- ---------- 2) คีย์ + บันทึกการเรียก ----------
create table if not exists public.ins_api_keys (
  id         bigserial primary key,
  name       text not null,                       -- ชื่อระบบที่ถือคีย์
  key_hash   text not null unique,                -- sha256 ของคีย์ (hex)
  scope      text not null default 'full' check (scope in ('full','basic')),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  last_used  timestamptz
);
create table if not exists public.ins_api_log (
  id         bigserial primary key,
  key_id     bigint,
  ip         text not null default '',
  n_rows     integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists ins_api_log_idx on public.ins_api_log (key_id, created_at desc);
alter table public.ins_api_keys enable row level security;      -- ไม่มี policy = เข้าได้เฉพาะ security definer
alter table public.ins_api_log  enable row level security;
revoke all on public.ins_api_keys, public.ins_api_log from anon, authenticated;
revoke all on sequence public.ins_api_keys_id_seq, public.ins_api_log_id_seq from anon, authenticated;

-- ออกคีย์ใหม่ — รันใน SQL Editor เท่านั้น · คืนคีย์จริง "ครั้งเดียว" (เก็บแค่แฮช)
create or replace function public.ins_api_key_new(p_name text, p_scope text default 'full')
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_key text := 'ins_' || replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  if coalesce(btrim(p_name), '') = '' then raise exception 'ต้องระบุชื่อระบบ'; end if;
  if p_scope not in ('full','basic') then raise exception 'scope ต้องเป็น full หรือ basic'; end if;
  insert into public.ins_api_keys (name, key_hash, scope)
  values (btrim(p_name), encode(sha256(convert_to(v_key, 'UTF8')), 'hex'), p_scope);
  return v_key;
end $$;
revoke all on function public.ins_api_key_new(text, text) from public, anon, authenticated;

-- ---------- 3) ตัวดึงข้อมูล ----------
--   p_since / p_after = ตำแหน่งที่ดึงถึงรอบก่อน (ค่า next ที่ได้กลับไป) · ว่าง = เริ่มจากใบแรก
--   p_status = new | contacted | quoted | done | cancelled (ว่าง = ทุกสถานะ)
--   p_brand  = toyota | hino (ว่าง = ทั้งคู่)
--   p_limit  = 1–500 (ค่าเริ่มต้น 200)
create or replace function public.ins_ext_requests(
  p_since  timestamptz default null,
  p_after  uuid        default null,
  p_status text        default null,
  p_brand  text        default null,
  p_limit  integer     default 200,
  p_key    text        default null      -- สำรอง: ส่งคีย์ใน body แทน header ได้ (บางระบบตั้ง header เองไม่ได้)
) returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_hdr   json := nullif(current_setting('request.headers', true), '')::json;
  v_raw   text := coalesce(nullif(v_hdr->>'x-api-key', ''), p_key, '');
  v_ip    text := coalesce(v_hdr->>'x-forwarded-for', '');
  v_k     public.ins_api_keys%rowtype;
  v_lim   integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_recent integer;
  v_data  jsonb;
  v_n     integer;
  v_last  jsonb;
  v_pii   text[] := array['id_card','birth_date','income','occupation','workplace','addr','moo','road','tambon',
                          'amphoe','province','zipcode','phone_home','phone_mobile','consent_at','consent_version'];
begin
  if length(v_raw) < 20 then
    raise exception 'ต้องส่ง X-API-Key' using errcode = '28000';
  end if;
  select * into v_k from public.ins_api_keys k
   where k.key_hash = encode(sha256(convert_to(v_raw, 'UTF8')), 'hex') and k.active;
  if not found then
    raise exception 'API key ไม่ถูกต้องหรือถูกปิดแล้ว' using errcode = '28000';
  end if;

  select count(*) into v_recent from public.ins_api_log l
   where l.key_id = v_k.id and l.created_at > now() - interval '1 minute';
  if v_recent >= 60 then
    raise exception 'เรียกถี่เกินไป (จำกัด 60 ครั้งต่อนาที)' using errcode = 'P0001';
  end if;

  with rows as (
    select r.*
      from public.ins_requests r
     where (p_since is null
            or (r.changed_at, r.id) > (p_since, coalesce(p_after, '00000000-0000-0000-0000-000000000000'::uuid)))
       and (coalesce(p_status, '') = '' or r.status = p_status)
       and (coalesce(p_brand, '')  = '' or r.brand  = p_brand)
     order by r.changed_at, r.id
     limit v_lim
  )
  select coalesce(jsonb_agg(
           ( case when v_k.scope = 'full'
                  then to_jsonb(x) - 'upload_token'
                  else (to_jsonb(x) - 'upload_token') - v_pii end )
           || jsonb_build_object(
                'assigned_name', (select e.name from public.ins_staff s
                                    join public.employees e on e.emp_id = s.emp_id and e.brand = coalesce(s.brand, 'toyota')
                                   where s.emp_id = x.assigned_to),
                'files', coalesce((select jsonb_agg(jsonb_build_object('name', f.name, 'tag', f.tag, 'mime', f.mime,
                                                                      'size', f.size, 'created_at', f.created_at)
                                                    order by f.created_at)
                                     from public.ins_files f where f.req_id = x.id), '[]'::jsonb))
           order by x.changed_at, x.id), '[]'::jsonb),
         count(*)::int,
         (select jsonb_build_object('since', y.changed_at, 'after', y.id)
            from rows y order by y.changed_at desc, y.id desc limit 1)
    into v_data, v_n, v_last
    from rows x;

  insert into public.ins_api_log (key_id, ip, n_rows) values (v_k.id, v_ip, v_n);
  update public.ins_api_keys set last_used = now() where id = v_k.id;

  return jsonb_build_object(
    'ok', true,
    'scope', v_k.scope,
    'count', v_n,
    'has_more', v_n >= v_lim,
    -- ส่งค่า next กลับมาเป็น p_since / p_after ในรอบถัดไป · ไม่มีแถวใหม่ = คืนค่าที่ส่งมา (ใช้ซ้ำได้)
    'next', coalesce(v_last, jsonb_build_object('since', p_since, 'after', p_after)),
    'server_time', now(),
    'data', v_data);
end;
$$;
revoke all on function public.ins_ext_requests(timestamptz, uuid, text, text, integer, text) from public;
grant execute on function public.ins_ext_requests(timestamptz, uuid, text, text, integer, text) to anon, authenticated;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ใช้งาน (รันใน SQL Editor ทีละคำสั่ง)
--
-- 1) ออกคีย์ให้ระบบปลายทาง — ผลที่ได้คือคีย์จริง แสดงครั้งเดียว คัดลอกไปให้ผู้ดูแลระบบนั้นทันที
--      select public.ins_api_key_new('ชื่อระบบปลายทาง', 'full');     -- หรือ 'basic' = ไม่มีข้อมูลส่วนบุคคล
--
-- 2) ดูคีย์ที่มี / ใช้ล่าสุดเมื่อไร
--      select id, name, scope, active, created_at, last_used from public.ins_api_keys order by id;
--
-- 3) ปิดคีย์ (รั่ว / เลิกใช้)
--      update public.ins_api_keys set active = false where id = <เลข id>;
--
-- 4) ดูประวัติการเรียก
--      select l.created_at, k.name, l.ip, l.n_rows from public.ins_api_log l
--        left join public.ins_api_keys k on k.id = l.key_id order by l.id desc limit 50;
--
-- ถอนออกทั้งหมด:
--   drop function if exists public.ins_ext_requests(timestamptz, uuid, text, text, integer, text);
--   drop function if exists public.ins_api_key_new(text, text);
--   drop table if exists public.ins_api_log, public.ins_api_keys;
--   (changed_at กับ trigger ปล่อยไว้ได้ ไม่กระทบอะไร)
-- ============================================================================
