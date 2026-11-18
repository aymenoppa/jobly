-- A worker is told what the app collects about where they are, once, before it saves any of it.
--
-- Clocking in and out saves where the phone is (settings.clock.record_location, on unless the
-- company turned it off), and with the clock at the property on (settings.clock.geofence) the phone
-- compares its position with the property while Jobly is open. Until now a worker saw one muted
-- line under the clock and the browser's own prompt. Several states' notice laws are worded around
-- other kinds of monitoring and may not reach this, but a written notice each worker acknowledges
-- once is cheap and would satisfy them if they did.
--
--   worker_notices   Which notice a person acknowledged, and when:
--                      clock_location      where they are is saved when they clock in and out
--                      clock_at_property   the phone compares its position with the property,
--                                          without saving it
--
-- The field app shows the notice before it first reads the phone's position for either, and keeps
-- no position until it's acknowledged (apps/web/src/features/field/locationNotice.ts). A row is
-- written only by acknowledge_worker_notices(), for the person signed in: nobody else can say
-- someone was told, and nobody can change the date or take it back. The worker reads their own; the
-- office reads the team's.
--
-- supabase/tests/location_notice_test.sql covers it.

create table public.worker_notices (
  company_id uuid not null references public.companies (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  notice text not null check (notice in ('clock_location', 'clock_at_property')),
  acknowledged_at timestamptz not null default now(),
  primary key (company_id, user_id, notice)
);
comment on table public.worker_notices is 'Notices a worker acknowledged about what the app collects (written by acknowledge_worker_notices only)';

alter table public.worker_notices enable row level security;
create policy worker_notices_read on public.worker_notices for select to authenticated using (
  user_id = (select auth.uid()) or private.has_role(company_id, '{owner,admin,office}')
);
revoke all on public.worker_notices from anon;
revoke insert, update, delete, truncate on public.worker_notices from authenticated;

-- The person signed in acknowledges notices for a company they work for (the team, or a sub with a
-- sign-in). `p_at` is when they tapped, for a phone that had no signal then: never later than now.
-- The first acknowledgement stands. Gives what's on record for them afterwards.
create function public.acknowledge_worker_notices(p_company uuid, p_notices text[], p_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null or not exists (
    select 1 from public.memberships m where m.company_id = p_company and m.user_id = v_user and m.active
  ) then
    raise exception 'You don''t have access to this company.' using errcode = '42501';
  end if;
  insert into public.worker_notices (company_id, user_id, notice, acknowledged_at)
  select p_company, v_user, n, least(coalesce(p_at, now()), now())
  from unnest(coalesce(p_notices, '{}')) as n
  where n in ('clock_location', 'clock_at_property')
  on conflict do nothing;
  return coalesce((select jsonb_object_agg(w.notice, w.acknowledged_at) from public.worker_notices w where w.company_id = p_company and w.user_id = v_user), '{}'::jsonb);
end $$;
revoke all on function public.acknowledge_worker_notices(uuid, text[], timestamptz) from public, anon;
grant execute on function public.acknowledge_worker_notices(uuid, text[], timestamptz) to authenticated;

-- The new table's policy looks up who's asking once per query, as every other table's do.
select private.fold_member_checks('public.worker_notices');

notify pgrst, 'reload schema';
