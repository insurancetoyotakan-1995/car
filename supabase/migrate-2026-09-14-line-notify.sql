-- =====================================================================
--  migrate 2026-09-14 (5) : แจ้งเตือนผ่าน LINE OA "แจ้งเตือนทำประกันภัย" (แยกจาก OA ใบสำคัญจ่าย)
--
--  ใครได้ข้อความ:
--  - ใบใหม่เข้ามา        → เจ้าหน้าที่ที่ระบบสุ่มให้ดูแล ("มีคำขอใหม่ ระบบให้คุณดูแล")
--                         + บัญชีผู้ดูแล (role = admin) ที่ผูก LINE ไว้ (สรุปว่าใครได้ใบนี้)
--  - บัญชีกลางย้ายผู้ดูแล → เจ้าหน้าที่คนใหม่
--  - ใครยังไม่มี line_user_id → ข้ามเงียบ ๆ (ไม่ error · ไม่ขวางการยื่นคำขอ)
--
--  วิธีทำงาน: trigger บน ins_requests → net.http_post (pg_net) ยิง LINE Messaging API
--  - pg_net ยิงแบบ async หลัง commit → ส่งคำขอไม่ช้าลง · LINE ล่มก็ยื่นคำขอได้ปกติ
--  - token เก็บใน Supabase Vault ชื่อ 'line_channel_token' (ไม่อยู่ในโค้ด/ไม่อยู่ใน repo)
--
--  วิธีใช้:
--  1) SQL Editor → วางทั้งไฟล์นี้ → Run (รันซ้ำได้)
--  2) ใส่ token (ทำครั้งเดียว — คนดูแลระบบใส่เอง):
--       select vault.create_secret('<Channel access token>', 'line_channel_token');
--     เปลี่ยน token ภายหลัง:
--       select vault.update_secret(id, '<token ใหม่>') from vault.secrets where name = 'line_channel_token';
--  3) รัน migrate-2026-09-14-line-link.sql — เจ้าหน้าที่ผูก LINE เองจาก staff.html
-- =====================================================================

create extension if not exists pg_net;

alter table public.ins_staff add column if not exists line_user_id text;

-- ---------- ส่งข้อความ 1 คน ----------
create or replace function public.ins_line_push(p_to text, p_text text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text;
begin
  if coalesce(p_to, '') = '' or coalesce(p_text, '') = '' then return; end if;
  select decrypted_secret into v_token
    from vault.decrypted_secrets where name = 'line_channel_token' limit 1;
  if coalesce(v_token, '') = '' then return; end if;          -- ยังไม่ใส่ token = ปิดแจ้งเตือน
  perform net.http_post(
    url     := 'https://api.line.me/v2/bot/message/push',
    body    := jsonb_build_object('to', p_to,
                 'messages', jsonb_build_array(jsonb_build_object('type', 'text', 'text', left(p_text, 4900)))),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_token),
    timeout_milliseconds := 8000);
exception when others then
  -- 🔑 แจ้งเตือนล้มต้องไม่ทำให้การยื่นคำขอ/ย้ายผู้ดูแลล้มตาม
  raise warning 'ins_line_push: %', sqlerrm;
end;
$$;

-- ---------- ประกอบข้อความ ----------
create or replace function public.ins_line_text(p_req public.ins_requests, p_head text, p_with_agent boolean)
returns text
language plpgsql stable
security definer
set search_path = public
as $$
declare
  v_agent text;
  v_refer boolean := p_req.kind = 'refer';
begin
  if p_with_agent then
    select coalesce(e.name, nullif(split_part(s.note, ' · ', 1), ''), s.emp_id) into v_agent
      from public.ins_staff s left join public.employees e on e.emp_id = s.emp_id
     where s.emp_id = p_req.assigned_to;
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
    || case when p_with_agent then E'\nผู้ดูแล: ' || coalesce(v_agent, 'ยังไม่มี') else '' end
    || E'\n\nเปิดดู: https://insurancetoyotakan-1995.github.io/car/staff.html?no=' || p_req.no;
end;
$$;

-- ---------- trigger ----------
create or replace function public.ins_notify_trg()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line text;
  a record;
begin
  begin
    if TG_OP = 'INSERT' then
      if NEW.assigned_to is not null then
        select line_user_id into v_line from public.ins_staff where emp_id = NEW.assigned_to and active;
        perform public.ins_line_push(v_line,
          public.ins_line_text(NEW, '🛡️ มีคำขอประกันใหม่ — ระบบให้คุณดูแล', false));
      end if;
      for a in select line_user_id from public.ins_staff
                where active and role = 'admin' and coalesce(line_user_id, '') <> ''
                  and line_user_id is distinct from v_line          -- คนเดียวกันไม่ต้องได้ 2 ข้อความ
      loop
        perform public.ins_line_push(a.line_user_id,
          public.ins_line_text(NEW, '🛡️ มีคำขอประกันใหม่', true));
      end loop;

    elsif TG_OP = 'UPDATE' and NEW.assigned_to is not null
          and NEW.assigned_to is distinct from OLD.assigned_to then
      select line_user_id into v_line from public.ins_staff where emp_id = NEW.assigned_to and active;
      perform public.ins_line_push(v_line,
        public.ins_line_text(NEW, '📌 มีคำขอประกันถูกมอบให้คุณดูแล', false));
    end if;
  exception when others then
    raise warning 'ins_notify_trg: %', sqlerrm;
  end;
  return NEW;
end;
$$;

drop trigger if exists ins_requests_notify on public.ins_requests;
create trigger ins_requests_notify
  after insert or update of assigned_to on public.ins_requests
  for each row execute function public.ins_notify_trg();

-- เรียกตรงจากหน้าเว็บไม่ได้ (ใช้ภายใน trigger เท่านั้น)
revoke all on function public.ins_line_push(text, text)                        from public, anon, authenticated;
revoke all on function public.ins_line_text(public.ins_requests, text, boolean) from public, anon, authenticated;
revoke all on function public.ins_notify_trg()                                  from public, anon, authenticated;
