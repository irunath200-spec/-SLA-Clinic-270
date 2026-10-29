-- ใช้เฉพาะ Supabase โปรเจกต์ใหม่ ตรวจ Project Ref ในหน้า SQL Editor ก่อนรัน
-- ไม่อ้างถึงหรือแก้ไขตาราง sla_data ของเว็บไซต์เดิม
-- รันเพียงครั้งเดียว: ถ้าตารางชื่อเดียวกันมีอยู่แล้ว สคริปต์จะหยุดและ rollback
begin;

create table public.sla_site_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.sla_site_admins enable row level security;
revoke all on public.sla_site_admins from public, anon, authenticated;
grant select on public.sla_site_admins to authenticated;
create policy "admin reads own membership" on public.sla_site_admins
  for select to authenticated using (user_id = (select auth.uid()));
-- เพิ่ม/ลบผู้ดูแลจาก SQL Editor เท่านั้น ผู้ใช้หน้าเว็บแก้รายชื่อผู้ดูแลไม่ได้

create function public.sla_v2_payload_is_safe(payload jsonb)
returns boolean language plpgsql immutable set search_path = '' as $$
declare item jsonb; idx integer;
begin
  if payload is null or jsonb_typeof(payload) <> 'object' then return false; end if;
  if payload->>'siteId' is distinct from 'delivery-sla-v2'
     or payload->'schemaVersion' is distinct from '2'::jsonb
     or payload->'salesRedacted' is distinct from 'true'::jsonb
     or jsonb_typeof(payload->'rows') is distinct from 'array'
     then return false; end if;
  if payload->'count' is distinct from to_jsonb(jsonb_array_length(payload->'rows')) then return false; end if;
  for item in select value from jsonb_array_elements(payload->'rows') loop
    if jsonb_typeof(item) <> 'array' then return false; end if;
    if jsonb_array_length(item) <> 82 then return false; end if;
    foreach idx in array array[11,12,13,14,15,17,18] loop
      if item->idx is distinct from 'null'::jsonb then return false; end if;
    end loop;
  end loop;
  return true;
end $$;
revoke all on function public.sla_v2_payload_is_safe(jsonb) from public;
grant execute on function public.sla_v2_payload_is_safe(jsonb) to anon, authenticated;

create table public.sla_dashboard_v2 (
  id text primary key check (id = 'delivery-sla-v2'),
  records jsonb not null check (public.sla_v2_payload_is_safe(records)),
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.sla_dashboard_v2 enable row level security;
revoke all on public.sla_dashboard_v2 from public, anon, authenticated;
grant select on public.sla_dashboard_v2 to anon, authenticated;
grant update (records) on public.sla_dashboard_v2 to authenticated;
-- ไม่มีสิทธิ์ insert/delete/truncate จากหน้าเว็บ
create policy "read new dashboard only" on public.sla_dashboard_v2
  for select to anon, authenticated using (id = 'delivery-sla-v2');
create policy "listed admins update new dashboard" on public.sla_dashboard_v2
  for update to authenticated
  using (id = 'delivery-sla-v2' and exists (
    select 1 from public.sla_site_admins where user_id = (select auth.uid())
  ))
  with check (id = 'delivery-sla-v2' and exists (
    select 1 from public.sla_site_admins where user_id = (select auth.uid())
  ));

create function public.sla_v2_set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = clock_timestamp(); return new; end $$;
revoke all on function public.sla_v2_set_updated_at() from public;
create trigger sla_v2_updated before update on public.sla_dashboard_v2
  for each row execute function public.sla_v2_set_updated_at();

insert into public.sla_dashboard_v2(id, records) values (
  'delivery-sla-v2',
  '{"siteId":"delivery-sla-v2","schemaVersion":2,"salesRedacted":true,"period":"","count":0,"rows":[]}'::jsonb
);
commit;

-- หลังสร้างผู้ดูแลใน Authentication > Users ของโปรเจกต์ใหม่:
-- แทน UUID ด้วย User ID จริง (ห้ามใช้ publishable key เป็น UUID)
-- insert into public.sla_site_admins(user_id)
-- values ('REPLACE_WITH_AUTH_USER_UUID'::uuid);

-- ถ้าจำเป็นต้องปิดการอ่านสาธารณะชั่วคราว:
-- revoke select on public.sla_dashboard_v2 from anon;
-- Dashboard ปัจจุบันจะอ่านไม่ได้จนกว่าจะเพิ่มระบบเข้าสู่ระบบผู้ชม
