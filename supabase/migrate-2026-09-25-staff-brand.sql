-- ============================================================================
-- เจ้าหน้าที่ประกันแยกตามบริษัท — 2026-09-25
--
-- ที่มา: ฮีโน่มีเจ้าหน้าที่ของตัวเอง 1 คน (อยู่ในทำเนียบฮีโน่ ไม่ใช่โตโยต้า)
--        ใบฮีโน่ต้องไปหาเธอเท่านั้น และเธอต้องไม่ถูกนับรวมในการแจกงานของโตโยต้า
--        🔑 รหัสเจ้าหน้าที่ฮีโน่ขึ้นต้นด้วย 1 เหมือนกัน ถ้าไม่แยกแบรนด์
--           เธอจะไปโผล่ในกลุ่ม "สำนักงานใหญ่" ของโตโยต้าแล้วรับใบโตโยต้าด้วย
--
-- ข้อตกลง (2026-09-25):
--   - ใบฮีโน่ → เจ้าหน้าที่ฮีโน่เท่านั้น · ใบโตโยต้า → ทีมโตโยต้าเท่านั้น
--   - เจ้าหน้าที่ฮีโน่ลา/พักแจก → ใบ "รอ" (ไม่มีผู้ดูแล) ไม่ตกไปทีมโตโยต้า
--     บัญชีกลางยังเห็นใบที่ไม่มีผู้ดูแลในหน้าเจ้าหน้าที่ และแจกมือได้
--
-- รายชื่อเจ้าหน้าที่ (ข้อมูลบุคคล) อยู่ในไฟล์ ins-staff-hino.sql ที่ gitignore ไว้
-- ปลอดภัยต่อการรันซ้ำ
-- ============================================================================

begin;

-- ---------- 1) คอลัมน์แบรนด์ของเจ้าหน้าที่ ----------
alter table public.ins_staff add column if not exists brand text not null default 'toyota';
alter table public.ins_staff drop constraint if exists ins_staff_brand_chk;
alter table public.ins_staff add constraint ins_staff_brand_chk check (brand in ('toyota','hino'));

-- ---------- 2) แจกงาน: ไม่ข้ามแบรนด์เด็ดขาด ----------
create or replace function public.ins_pick_assignee(p_emp text, p_kind text, p_brand text default 'toyota')
returns text
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v  text;
  vb text := public.ins_brand(p_brand);
  vg text;                       -- หลักแรกของรหัสพนักงานผู้ขอ = รหัสกลุ่มสาขา (เฉพาะโตโยต้า)
begin
  -- 🔑 ล็อกกันยื่นพร้อมกัน 2 ใบแล้วได้คนเดียวกัน (ค้างจนจบทรานแซกชันของ ins_submit)
  perform pg_advisory_xact_lock(hashtext('ins_pick_assignee'));

  if p_kind = 'self' and coalesce(p_emp, '') <> '' then
    -- 1) ใบล่าสุดในระบบนี้ (แบรนด์เดียวกัน)
    select r.assigned_to into v
      from public.ins_requests r
      join public.ins_staff s on s.emp_id = r.assigned_to
       and s.active and s.role = 'agent' and s.takes_new and s.brand = vb
     where r.emp_id = p_emp and r.brand = vb and r.kind = 'self' and r.status <> 'cancelled'
     order by r.created_at desc
     limit 1;
    if v is not null then return v; end if;

    -- 2) ข้อมูลกรมธรรม์เดิมจาก Excel
    select o.agent_emp_id into v
      from public.ins_emp_owner o
      join public.ins_staff s on s.emp_id = o.agent_emp_id
       and s.active and s.role = 'agent' and s.takes_new and s.brand = vb
     where o.emp_id = p_emp and o.brand = vb;
    if v is not null then return v; end if;
  end if;

  -- 3) กลุ่มตามหลักแรกของรหัส (เฉพาะโตโยต้า) — ใช้กับทั้งใบทำเองและใบแนะนำลูกค้า
  --    ในกลุ่มเดียวกันยังแจกให้คนที่ถือใบน้อยสุดก่อน เสมอกันสุ่ม (นับใบทุกแบรนด์ = ภาระงานจริง)
  if vb = 'toyota' and left(coalesce(p_emp, ''), 1) ~ '^[0-9]$' then
    vg := left(p_emp, 1);
    select s.emp_id into v
      from public.ins_staff s
      left join public.ins_requests r
             on r.assigned_to = s.emp_id and r.status <> 'cancelled'
     where s.active and s.role = 'agent' and s.takes_new and s.brand = 'toyota'
       and left(s.emp_id, 1) = vg
     group by s.emp_id
     order by count(r.id), random()
     limit 1;
    if v is not null then return v; end if;
  end if;

  -- 4) ทั้งแผนกของแบรนด์นั้น: ใครมีใบสะสมน้อยสุดได้ก่อน เสมอกันสุ่ม
  --    ฮีโน่มีคนเดียว → ได้เธอเสมอ · เธอพักแจก/ปิดบัญชี → คืน null = ใบรอไม่มีผู้ดูแล
  --    (ตั้งใจให้เป็นแบบนี้ ผู้ใช้เลือก "รอเธอกลับมา" ไม่ให้ตกไปทีมโตโยต้า)
  select s.emp_id into v
    from public.ins_staff s
    left join public.ins_requests r
           on r.assigned_to = s.emp_id and r.status <> 'cancelled'
   where s.active and s.role = 'agent' and s.takes_new and s.brand = vb
   group by s.emp_id
   order by count(r.id), random()
   limit 1;
  return v;
end;
$$;

revoke all on function public.ins_pick_assignee(text, text, text) from public, anon, authenticated;

-- ---------- 3) ชื่อเจ้าหน้าที่: หาจากทำเนียบของแบรนด์ตัวเอง ----------
--   เดิมทุกฟังก์ชัน join ทำเนียบแบบ e.brand = 'toyota' ตายตัว (migrate-2026-09-21-brand)
--   → เจ้าหน้าที่ฮีโน่จะหาชื่อไม่เจอ แล้วโชว์เป็นรหัสพนักงานเปล่า ๆ
--   แก้เป็นอิงแบรนด์ของแถวเจ้าหน้าที่เอง
do $f$
declare
  fn  text;
  d   text;
  old text := 'employees e on e.emp_id = s.emp_id and e.brand = ''toyota''';
  new text := 'employees e on e.emp_id = s.emp_id and e.brand = coalesce(s.brand, ''toyota'')';
begin
  foreach fn in array array['public.ins_whoami()', 'public.ins_agents()',
                            'public.ins_viewer_agents()',
                            'public.ins_line_bind_srv(text, text)',
                            'public.ins_submit(jsonb)'] loop
    if to_regprocedure(fn) is null then
      raise notice 'ไม่พบฟังก์ชัน % — ข้าม', fn;
      continue;
    end if;
    d := pg_get_functiondef(fn::regprocedure);
    if position('coalesce(s.brand' in d) > 0 then
      raise notice '% อิงแบรนด์เจ้าหน้าที่ไว้แล้ว — ข้าม', fn;
    elsif position(old in d) = 0 then
      raise notice '% ไม่มี join แบบที่จะแก้ — ข้าม', fn;
    else
      execute replace(d, old, new);
    end if;
  end loop;
end $f$;

commit;

notify pgrst, 'reload schema';

-- ============================================================================
-- ⚠️ ต่อจากนี้ต้องรัน ins-staff-hino.sql เพื่อเพิ่มตัวเจ้าหน้าที่ฮีโน่
--    ถ้ายังไม่รัน ใบฮีโน่จะไม่มีผู้ดูแล (ระบบไม่พัง แต่ไม่มีใครถือใบ)
--
-- ตรวจหลังรัน (คัดลอกไปรันแยก)
--
-- A) เจ้าหน้าที่แต่ละแบรนด์
--   select s.brand, s.emp_id,
--          coalesce(e.name, nullif(split_part(s.note,' · ',1),''), s.emp_id) as ชื่อ,
--          s.takes_new as รับงานใหม่
--     from public.ins_staff s
--     left join public.employees e on e.emp_id = s.emp_id and e.brand = coalesce(s.brand,'toyota')
--    where s.active and s.role = 'agent'
--    order by s.brand, s.emp_id;
--
-- B) ลองแจกจริงโดยไม่บันทึก — ฮีโน่ต้องได้คนเดียวกันทุกครั้ง ไม่ใช่คนโตโยต้า
--   begin;
--     select 'ฮีโน่ รหัส 1'   as เคส, public.ins_pick_assignee('11001008','self','hino')   as ได้คนนี้
--     union all select 'ฮีโน่ รหัสอื่น',  public.ins_pick_assignee('13001001','refer','hino')
--     union all select 'โตโยต้า กลุ่ม 1', public.ins_pick_assignee('11001234','refer','toyota')
--     union all select 'โตโยต้า กลุ่ม 2', public.ins_pick_assignee('21001234','refer','toyota')
--     union all select 'โตโยต้า กลุ่ม 3', public.ins_pick_assignee('31001234','refer','toyota');
--   rollback;
-- ============================================================================
