-- Who is on a visit: one rule everywhere.
--
-- A visit has a crew (visits.crew_id) and, apart from it, people (visit_assignees). Recurring visits
-- and visits made in bulk get a crew and no people, and "who's on it" went by the people only: a
-- field crew member couldn't see their crew's recurring visits at all, nobody heard when one moved
-- or was cancelled, and it was on nobody's calendar.
--
-- Now: the people on a visit are the people listed on it, and when nobody is listed, the members
-- of its crew (crew_members). private.visit_people() says who, and everything below goes by it:
--
--   1. What field crew can see and work: their visits (private.assigned_to_visit and its list,
--      private.my_visits and so the jobs, clients, properties and requests behind them), changing
--      a visit's status, and its gate code on the day.
--   2. Schedule notifications: moved, cancelled and deleted visits tell the people on them by this
--      rule, and a new visit for a crew tells its members they're on it (not the visits the nightly
--      task makes for recurring jobs). Listing the first person on a crew's visit takes the rest of
--      the crew off it (they hear), and taking the last one off puts the crew back on. On it and
--      off it again within moments is no news.
--   3. A visit that moves to another crew: the old crew's members listed on it come off and the new
--      crew's go on (people picked by hand who aren't on the old crew stay); with nobody listed, the
--      old crew hears they're off it and the new crew that they're on it.
--
-- (A change to a recurring job's whole schedule is told once to each person rather than once for
-- every visit: 20261113000220_recurring_schedule_one_notice.sql.)

-- ---------------------------------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------------------------------

create function private.visit_people(p_visit uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a.user_id from public.visit_assignees a where a.visit_id = p_visit
  union all
  select m.user_id from public.visits v join public.crew_members m on m.crew_id = v.crew_id
  where v.id = p_visit and not exists (select 1 from public.visit_assignees a where a.visit_id = p_visit)
$$;
revoke all on function private.visit_people(uuid) from public;
grant execute on function private.visit_people(uuid) to service_role;

-- A crew's visits are looked up by the crew now (a member's visits with nobody listed).
create index visits_crew_idx on public.visits (crew_id) where crew_id is not null;

-- ---------------------------------------------------------------------------------------------
-- 1. What field crew see and work
-- ---------------------------------------------------------------------------------------------

-- Am I on this visit? (Was: am I listed on it.)
create or replace function private.assigned_to_visit(p_visit uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.visit_assignees a where a.visit_id = p_visit and a.user_id = (select auth.uid()))
      or exists (
        select 1 from public.visits v join public.crew_members m on m.crew_id = v.crew_id
        where v.id = p_visit and m.user_id = (select auth.uid())
          and not exists (select 1 from public.visit_assignees a where a.visit_id = v.id)
      )
$$;

-- The same as a list, which policies check each row against (20261018000990_policy_lookups.sql).
create or replace function private.my_assigned_visits() returns setof uuid
language sql stable security definer set search_path = '' as $$
  select a.visit_id from public.visit_assignees a where a.user_id = (select auth.uid())
  union all
  select v.id from public.crew_members m join public.visits v on v.crew_id = m.crew_id
  where m.user_id = (select auth.uid()) and not exists (select 1 from public.visit_assignees a where a.visit_id = v.id)
$$;

-- And as rows, for the jobs, clients, properties and requests behind them (private.crew_sees_*
-- and their lists read this).
create or replace function private.my_visits() returns setof public.visits
language sql stable security definer set search_path = '' as $$
  select v.* from public.visits v join public.visit_assignees a on a.visit_id = v.id where a.user_id = (select auth.uid())
  union all
  select v.* from public.crew_members m join public.visits v on v.crew_id = m.crew_id
  where m.user_id = (select auth.uid()) and not exists (select 1 from public.visit_assignees a where a.visit_id = v.id)
$$;

-- assigned_to_visit's body changed, and its list with it: the bodies the lists mirror, as in
-- 20261025002002_sub_sign_ins.sql with that one line changed.
create or replace function private.folded_helpers() returns table (helper text, body text)
language sql immutable set search_path = '' as $$
  values
    ('private.has_role(uuid,public.member_role[])', 'select exists ( select 1 from public.memberships m where m.company_id = p_company and m.user_id = (select auth.uid()) and m.active and m.role = any (p_roles) )'),
    ('private.has_perm(uuid,text)', 'select coalesce(( select case when r.id is null then p_perm = any (private.level_permissions(m.role)) else p_perm = any (r.permissions) end from public.memberships m left join public.company_roles r on r.id = m.role_id where m.company_id = p_company and m.user_id = (select auth.uid()) and m.active ), false)'),
    ('private.is_member(uuid)', 'select exists ( select 1 from public.memberships m where m.company_id = p_company and m.user_id = (select auth.uid()) and m.active and m.role <> ''subcontractor'' )'),
    ('private.manages_equipment(uuid)', 'select private.has_role(p_company, ''{owner,admin,office,estimator,crew_lead}'') and private.has_perm(p_company, ''equipment'')'),
    ('private.schedules_crew(uuid,uuid)', 'select (private.has_role(p_company, ''{owner,admin,office,estimator,crew_lead}'') and private.has_perm(p_company, ''schedule'')) or (private.has_role(p_company, ''{crew_lead}'') and p_crew is not null and exists (select 1 from private.my_crews(p_company) as mine(crew_id) where mine.crew_id = p_crew))'),
    ('private.my_crews(uuid)', 'select c.id from public.crews c where c.company_id = p_company and c.lead_user_id = (select auth.uid()) union select m.crew_id from public.crew_members m where m.company_id = p_company and m.user_id = (select auth.uid())'),
    ('private.on_my_crew(uuid,uuid)', 'select p_user = (select auth.uid()) or exists ( select 1 from private.my_crews(p_company) as mine(crew_id) where exists (select 1 from public.crew_members m where m.crew_id = mine.crew_id and m.user_id = p_user) or exists (select 1 from public.crews c where c.id = mine.crew_id and c.lead_user_id = p_user) )'),
    ('private.assigned_to_visit(uuid)', 'select exists (select 1 from public.visit_assignees a where a.visit_id = p_visit and a.user_id = (select auth.uid())) or exists ( select 1 from public.visits v join public.crew_members m on m.crew_id = v.crew_id where v.id = p_visit and m.user_id = (select auth.uid()) and not exists (select 1 from public.visit_assignees a where a.visit_id = v.id) )'),
    ('private.works_visit(uuid)', 'select exists (select 1 from public.visit_assignees a where a.visit_id = p_visit and a.user_id = (select auth.uid())) or exists ( select 1 from public.visits v join public.crews c on c.id = v.crew_id where v.id = p_visit and (c.lead_user_id = (select auth.uid()) or exists (select 1 from public.crew_members m where m.crew_id = c.id and m.user_id = (select auth.uid()))) )'),
    ('private.visit_crew(uuid)', 'select crew_id from public.visits where id = p_visit'),
    ('private.crew_sees_client(uuid)', 'select exists ( select 1 from private.my_visits() v left join public.jobs j on j.id = v.job_id left join public.requests r on r.id = v.request_id left join public.properties p on p.id = v.property_id where p_client in (j.client_id, r.client_id, p.client_id) )'),
    ('private.crew_sees_job(uuid)', 'select exists (select 1 from private.my_visits() v where v.job_id = p_job)'),
    ('private.crew_sees_property(uuid)', 'select exists ( select 1 from private.my_visits() v left join public.jobs j on j.id = v.job_id left join public.requests r on r.id = v.request_id where p_property in (v.property_id, j.property_id, r.property_id) )'),
    ('private.crew_sees_request(uuid)', 'select exists (select 1 from private.my_visits() v where v.request_id = p_request)')
$$;

-- Changing a visit's status and notes: the people on it (was: the people listed on it).
alter policy visits_update_assigned on public.visits
  using (private.assigned_to_visit(id));

-- Gate codes on the day: the people on a visit at the property (20261018000100_audit_fixes.sql,
-- with "listed on it" now "on it").
drop policy property_access_read on public.property_access;
create policy property_access_read on public.property_access for select to authenticated using (
  private.has_role(company_id, '{owner,admin,office}')
  or exists (
    select 1 from public.visits v
    where v.property_id = property_access.property_id
      and private.assigned_to_visit(v.id)
      and v.status not in ('completed', 'cancelled')
      and case when v.starts_at is not null
               then v.starts_at between now() - interval '12 hours' and now() + interval '24 hours'
               else v.scheduled_on between private.company_today(v.company_id) and private.company_today(v.company_id) + 1 end
  )
);

-- ---------------------------------------------------------------------------------------------
-- 2. Schedule notifications go to the people on the visit
-- ---------------------------------------------------------------------------------------------

-- The server's changes to a whole recurring schedule are made quietly and told once
-- (20261113000220_recurring_schedule_one_notice.sql sets this for the length of its changes).
create function private.schedule_quiet() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(current_setting('jobly.schedule_quiet', true), '') = 'on'
$$;

-- Take a line back out of the person's schedule notification while it still waits (the same
-- notification private.notify_schedule would add to). True when it was there. "You're on it" and
-- then "you're off it" within moments, or the other way round, is no news: a visit made for a crew
-- and then given to one person on it tells the others nothing.
create function private.schedule_line_taken_back(p_company uuid, p_user uuid, p_line text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_prev public.notifications; v_lines text[];
begin
  select * into v_prev from public.notifications
  where company_id = p_company and user_id = p_user and kind = 'schedule'
    and read_at is null and delivered_at is null and delivery_attempts = 0 and delivery_failed_at is null
    and created_at > now() - interval '10 minutes'
  order by created_at desc limit 1
  for update;
  if not found or not (p_line = any (string_to_array(v_prev.body, E'\n'))) then
    return false;
  end if;
  v_lines := array_remove(string_to_array(v_prev.body, E'\n'), p_line);
  delete from public.notifications where id = v_prev.id;
  if cardinality(v_lines) > 0 then
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    values (p_company, p_user, 'schedule',
            case when cardinality(v_lines) = 1 then left(v_lines[1], 300) else format('%s changes to your schedule', cardinality(v_lines)) end,
            array_to_string(v_lines, E'\n'), '/field');
  end if;
  return true;
end $$;

-- Tell someone they're on a visit, or off it, at the time given (the visit's own, or the one it had).
create function private.notify_on_visit(v public.visits, p_user uuid, p_on boolean, p_when text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_on constant text := format('You''re on %s: %s', v.title, p_when);
  v_off constant text := format('You''re off %s (%s)', v.title, p_when);
begin
  if p_user is null or p_user = (select auth.uid()) then
    return; -- they made the change themselves, as in notify_schedule
  end if;
  if private.schedule_line_taken_back(v.company_id, p_user, case when p_on then v_off else v_on end) then
    return;
  end if;
  perform private.notify_schedule(v.company_id, p_user, v.id, case when p_on then v_on else v_off end);
end $$;

-- As in 20261017002200_notification_delivery.sql, to the people on it by the rule. Someone who came
-- onto it with a new crew in the same change has just been told they're on it (3, below).
create or replace function private.visit_change_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_tz text; v_line text; r record;
begin
  if private.schedule_quiet() then return null; end if;
  select timezone into v_tz from public.companies where id = new.company_id;
  if new.status = 'cancelled' and old.status is distinct from 'cancelled' then
    if not private.visit_is_upcoming(old, v_tz) then return null; end if;
    v_line := format('%s on %s was cancelled', new.title, private.visit_when(old.starts_at, old.scheduled_on, v_tz));
  elsif (new.starts_at is distinct from old.starts_at or new.scheduled_on is distinct from old.scheduled_on)
        and (private.visit_is_upcoming(new, v_tz) or private.visit_is_upcoming(old, v_tz)) and new.status <> 'cancelled' then
    v_line := case
      when new.status = 'unscheduled' or (new.starts_at is null and new.scheduled_on is null)
        then format('%s is off the schedule for now (was %s)', new.title, private.visit_when(old.starts_at, old.scheduled_on, v_tz))
      when coalesce(new.scheduled_on, '-infinity') = coalesce(old.scheduled_on, '-infinity')
        then format('%s now starts %s', new.title, private.visit_when(new.starts_at, new.scheduled_on, v_tz))
      else format('%s moved to %s (was %s)', new.title, private.visit_when(new.starts_at, new.scheduled_on, v_tz), private.visit_when(old.starts_at, old.scheduled_on, v_tz))
    end;
  else
    return null;
  end if;
  for r in
    select p.user_id from private.visit_people(new.id) as p(user_id)
    where new.crew_id is not distinct from old.crew_id
       or not exists (select 1 from public.crew_members m where m.crew_id = new.crew_id and m.user_id = p.user_id)
       or exists (select 1 from public.crew_members m where m.crew_id = old.crew_id and m.user_id = p.user_id)
  loop
    perform private.notify_schedule(new.company_id, r.user_id, new.id, v_line);
  end loop;
  return null;
end $$;

create or replace function private.visit_delete_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_tz text; r record;
begin
  if private.schedule_quiet() then return old; end if;
  select timezone into v_tz from public.companies where id = old.company_id;
  if not found or not private.visit_is_upcoming(old, v_tz) then
    return old; -- the company is being deleted, or it's old work
  end if;
  -- No link to the visit: it's about to be gone.
  for r in select p.user_id from private.visit_people(old.id) as p(user_id) loop
    perform private.notify_schedule(old.company_id, r.user_id, null,
      format('%s on %s was cancelled', old.title, private.visit_when(old.starts_at, old.scheduled_on, v_tz)));
  end loop;
  return old;
end $$;

-- People listed on a visit, or taken off it. Once for each statement rather than each row, to know
-- who was on the visit before: with nobody listed it was the crew, so the first person listed takes
-- the rest of the crew off (and is only told if they weren't on it already), and taking the last
-- one off puts the crew back on.
create function private.assignees_added_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; v public.visits; v_tz text; v_crew uuid[]; u uuid;
begin
  if private.schedule_quiet() then return null; end if;
  for r in select n.visit_id, array_agg(n.user_id) as users from added n group by n.visit_id loop
    select * into v from public.visits where id = r.visit_id;
    continue when not found;
    select timezone into v_tz from public.companies where id = v.company_id;
    continue when not private.visit_is_upcoming(v, v_tz);
    -- Nobody was listed before these: the crew was on it.
    v_crew := '{}';
    if v.crew_id is not null and not exists (select 1 from public.visit_assignees a where a.visit_id = v.id and a.user_id <> all (r.users)) then
      v_crew := array(select m.user_id from public.crew_members m where m.crew_id = v.crew_id);
    end if;
    foreach u in array r.users loop
      if u <> all (v_crew) then
        perform private.notify_on_visit(v, u, true, private.visit_when(v.starts_at, v.scheduled_on, v_tz));
      end if;
    end loop;
    foreach u in array v_crew loop
      if u <> all (r.users) then
        perform private.notify_on_visit(v, u, false, private.visit_when(v.starts_at, v.scheduled_on, v_tz));
      end if;
    end loop;
  end loop;
  return null;
end $$;

create function private.assignees_removed_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare r record; v public.visits; v_tz text; v_crew uuid[]; u uuid;
begin
  if private.schedule_quiet() then return null; end if;
  for r in select o.visit_id, array_agg(o.user_id) as users from removed o group by o.visit_id loop
    select * into v from public.visits where id = r.visit_id;
    continue when not found; -- the visit itself was deleted; visit_delete_notify told everyone
    select timezone into v_tz from public.companies where id = v.company_id;
    continue when not private.visit_is_upcoming(v, v_tz);
    -- Nobody is listed now: the crew is on it.
    v_crew := '{}';
    if v.crew_id is not null and not exists (select 1 from public.visit_assignees a where a.visit_id = v.id) then
      v_crew := array(select m.user_id from public.crew_members m where m.crew_id = v.crew_id);
    end if;
    foreach u in array r.users loop
      if u <> all (v_crew) then
        perform private.notify_on_visit(v, u, false, private.visit_when(v.starts_at, v.scheduled_on, v_tz));
      end if;
    end loop;
    foreach u in array v_crew loop
      if u <> all (r.users) then
        perform private.notify_on_visit(v, u, true, private.visit_when(v.starts_at, v.scheduled_on, v_tz));
      end if;
    end loop;
  end loop;
  return null;
end $$;

-- A new visit with a crew: its members are on it from the start, and hear as someone listed on it
-- would. Not the visits the nightly task makes for recurring jobs (a year of them at a time).
create function private.visit_crew_told() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_tz text; r record;
begin
  if private.schedule_quiet() then return null; end if;
  select timezone into v_tz from public.companies where id = new.company_id;
  if not private.visit_is_upcoming(new, v_tz) then return null; end if;
  for r in select m.user_id from public.crew_members m where m.crew_id = new.crew_id loop
    perform private.notify_on_visit(new, r.user_id, true, private.visit_when(new.starts_at, new.scheduled_on, v_tz));
  end loop;
  return null;
end $$;
create trigger crew_told after insert on public.visits
  for each row when (new.crew_id is not null and new.recurrence_key is null) execute function private.visit_crew_told();

drop trigger notify_people on public.visit_assignees;
drop function private.assignee_notify();
create trigger notify_people_added after insert on public.visit_assignees
  referencing new table as added for each statement execute function private.assignees_added_notify();
create trigger notify_people_removed after delete on public.visit_assignees
  referencing old table as removed for each statement execute function private.assignees_removed_notify();

-- ---------------------------------------------------------------------------------------------
-- 3. A visit that moves to another crew
-- ---------------------------------------------------------------------------------------------

-- Dragging a visit to another crew's lane (or picking another crew) left the old crew's people
-- listed on it, so they kept seeing it and the new crew never did. Now, when its crew changes:
-- with the old crew's members among the people listed, they come off and the new crew's go on
-- (anyone picked by hand who isn't on the old crew stays), and the triggers above tell each of
-- them; with nobody listed, the crews are the people on it, and are told here. A list with none of
-- the old crew on it was picked by hand, and stays as it is.
create function private.visit_crew_people() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_tz text; r record;
begin
  if exists (select 1 from public.visit_assignees a where a.visit_id = new.id) then
    if old.crew_id is not null and exists (
      select 1 from public.visit_assignees a join public.crew_members m on m.user_id = a.user_id and m.crew_id = old.crew_id
      where a.visit_id = new.id
    ) then
      -- The new crew's first, so the list is never empty in between (which would read as "the crew").
      insert into public.visit_assignees (company_id, visit_id, user_id)
      select new.company_id, new.id, m.user_id from public.crew_members m where m.crew_id = new.crew_id
      on conflict do nothing;
      delete from public.visit_assignees a
      where a.visit_id = new.id
        and exists (select 1 from public.crew_members m where m.crew_id = old.crew_id and m.user_id = a.user_id)
        and not exists (select 1 from public.crew_members m where m.crew_id = new.crew_id and m.user_id = a.user_id);
    end if;
    return null;
  end if;
  if private.schedule_quiet() then return null; end if;
  select timezone into v_tz from public.companies where id = new.company_id;
  if not private.visit_is_upcoming(new, v_tz) then return null; end if;
  for r in
    select m.user_id from public.crew_members m where m.crew_id = old.crew_id
      and not exists (select 1 from public.crew_members n where n.crew_id = new.crew_id and n.user_id = m.user_id)
  loop
    perform private.notify_on_visit(new, r.user_id, false, private.visit_when(old.starts_at, old.scheduled_on, v_tz));
  end loop;
  for r in
    select m.user_id from public.crew_members m where m.crew_id = new.crew_id
      and not exists (select 1 from public.crew_members o where o.crew_id = old.crew_id and o.user_id = m.user_id)
  loop
    perform private.notify_on_visit(new, r.user_id, true, private.visit_when(new.starts_at, new.scheduled_on, v_tz));
  end loop;
  return null;
end $$;
-- Named to fire before notify_people_on_change (triggers on a row fire in name order), so a move
-- to another crew and another day at once tells the people who are on it afterwards.
create trigger crew_people after update of crew_id on public.visits
  for each row when (old.crew_id is distinct from new.crew_id) execute function private.visit_crew_people();

revoke all on function private.schedule_quiet(), private.assignees_added_notify(), private.assignees_removed_notify(),
  private.visit_crew_people(), private.visit_crew_told(),
  private.schedule_line_taken_back(uuid, uuid, text), private.notify_on_visit(public.visits, uuid, boolean, text) from public;

-- The policies changed above check their rows against the lists, like the rest.
select private.fold_member_checks();

notify pgrst, 'reload schema';
