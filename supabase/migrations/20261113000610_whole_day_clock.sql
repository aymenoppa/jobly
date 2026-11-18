-- A whole-day clock, as a company setting.
--
-- The clock ran only while a visit was in progress: Start visit started it and Complete visit
-- stopped it. Driving between visits and time at the yard were on it only if the person opened the
-- clock's menu and picked Driving each time, so a tech who followed the three big buttons was paid
-- for time on site and nothing else.
--
-- companies.settings.clock.mode says how the clock works (Settings → Company → Time clock;
-- packages/core/src/clock.ts reads it the same way):
--
--   'visits'   As it was. A company with nothing saved is on this, so every existing company
--              stays as it is.
--   'day'      The clock runs all day. On my way starts it on travel and Start visit moves it onto
--              the visit (the field app does both, for the person who taps). Complete visit moves
--              everyone on that visit's clock to travel instead of stopping it: that part is here,
--              in the rule that ends a finished visit's clocks (20261113000600). The day ends when
--              the person stops their clock.
--
-- A company made from now on starts on 'day' (the trigger below sets it as the row is added, when
-- the row doesn't say).
--
-- Travel is the Driving timer that was already there (category 'drive', no visit and no job): paid
-- time for the person, on no job's costs, as a Driving timer always was.
--
-- A subcontractor's clock never moves to travel: finishing a visit ends it, in either mode.
--
-- The hourly upkeep (public.clock_upkeep) measured a clock from when it started. A whole-day clock
-- is a run of entries, each starting where the last ended, so in 'day' it's measured from the start
-- of the run: the reminder comes 10 hours after the person clocked in, not 10 hours after their
-- last visit, and the clock is stopped once the day has run 16 hours. 'visits' is as before.
--
-- supabase/tests/whole_day_clock_test.sql covers it.

create function private.clock_mode(p_company uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case when (select c.settings -> 'clock' ->> 'mode' from public.companies c where c.id = p_company) = 'day' then 'day' else 'visits' end
$$;
revoke all on function private.clock_mode(uuid) from public;

-- A new company starts on the whole-day clock, unless the row says how its clock works.
create function private.company_clock_default() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.settings -> 'clock' ->> 'mode' is null then
    new.settings := jsonb_set(coalesce(new.settings, '{}'), '{clock}',
      case when jsonb_typeof(new.settings -> 'clock') = 'object' then new.settings -> 'clock' else '{}'::jsonb end || '{"mode": "day"}'::jsonb);
  end if;
  return new;
end $$;
revoke all on function private.company_clock_default() from public;
create trigger clock_default before insert on public.companies
  for each row execute function private.company_clock_default();

-- One clock still running on a visit that was finished at p_at (20261113000600, with the whole-day
-- clock added): on the whole-day clock a team member's clock moves to travel there instead of
-- stopping.
create or replace function private.finished_visit_clock(p_entry uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  e public.time_entries;
  v_tz text;
  v_end timestamptz;
  v_next timestamptz;
  v_travels boolean;
begin
  select * into e from public.time_entries where id = p_entry and ended_at is null and approved_at is null;
  if not found then
    return;
  end if;
  v_travels := private.clock_mode(e.company_id) = 'day' and exists (
    select 1 from public.memberships m where m.company_id = e.company_id and m.user_id = e.user_id and m.active and m.role <> 'subcontractor');
  if v_travels then
    -- A clock is about to start for them: one start at a time for a person, taken before their
    -- running clock is held, the order any clock-in takes the two (private.one_running_clock).
    perform pg_advisory_xact_lock(hashtextextended('clock:' || e.company_id::text || ':' || e.user_id::text, 0));
  end if;
  -- As it is now, and held: a stop from the person's own phone at the same moment goes first or waits.
  select * into e from public.time_entries where id = p_entry and ended_at is null and approved_at is null for update;
  if not found then
    return;
  end if;
  select coalesce(c.timezone, 'UTC') into v_tz from public.companies c where c.id = e.company_id;
  if private.paid_for(e.company_id, e.user_id, (e.started_at at time zone v_tz)::date) then
    return;
  end if;
  -- At least a second long, for a clock dated ahead of this server (a phone whose clock runs fast).
  v_end := greatest(case when e.started_at < p_at then p_at else now() end, e.started_at + interval '1 second');
  select min(o.started_at) into v_next from public.time_entries o
  where o.company_id = e.company_id and o.user_id = e.user_id and o.id <> e.id and o.started_at > e.started_at and o.started_at < v_end;
  update public.time_entries set ended_at = coalesce(v_next, v_end) where id = e.id;
  -- Travel from there, unless later time of theirs already begins there or that day is paid. It
  -- starts a millisecond on: a phone still on the previous app version stops whatever it finds
  -- running from before its own Complete, and would take this for it if the two were the same instant.
  if v_travels and v_next is null and not private.paid_for(e.company_id, e.user_id, (v_end at time zone v_tz)::date) then
    insert into public.time_entries (company_id, user_id, category, started_at) values (e.company_id, e.user_id, 'drive', v_end + interval '1 millisecond');
  end if;
end $$;

-- When the unbroken run of time this entry belongs to began: back through the person's entries
-- that each end where the next begins (within a minute), a day at a time and two days at most.
create function private.clock_run_start(p_entry uuid) returns timestamptz
language plpgsql stable security definer set search_path = '' as $$
declare
  e public.time_entries;
  v_start timestamptz;
  v_prev timestamptz;
begin
  select * into e from public.time_entries where id = p_entry;
  if not found then
    return null;
  end if;
  v_start := e.started_at;
  loop
    select max(t.started_at) into v_prev from public.time_entries t
    where t.company_id = e.company_id and t.user_id = e.user_id and t.id <> e.id
      and t.started_at < v_start and t.started_at > v_start - interval '1 day'
      and t.ended_at > v_start - interval '1 minute' and t.ended_at <= v_start + interval '1 second';
    exit when v_prev is null or v_prev < e.started_at - interval '2 days';
    v_start := v_prev;
  end loop;
  return v_start;
end $$;
revoke all on function private.clock_run_start(uuid) from public;

-- 20261018000400_timezone_checks.sql, with the whole-day clock measured from the start of its run.
create or replace function public.clock_upkeep() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r record; v_reminded integer := 0; v_stopped integer := 0; v_end timestamptz; v_local text; v_since timestamptz;
begin
  for r in
    select te.id, te.company_id, te.user_id, te.started_at, c.timezone,
           coalesce(private.clock_hours(c.settings -> 'clock' ->> 'remind_after_hours'), 10) as remind_after,
           coalesce(private.clock_hours(c.settings -> 'clock' ->> 'stop_after_hours'), 16) as stop_after,
           -- The end of the working day, or 18:00 when it isn't a time.
           coalesce(case when pg_catalog.pg_input_is_valid(c.settings -> 'working_hours' ->> 'end', 'time')
                         then (c.settings -> 'working_hours' ->> 'end')::time end, '18:00') as day_end,
           coalesce(c.settings -> 'clock' ->> 'mode' = 'day', false) as whole_day
    from public.time_entries te
    join public.companies c on c.id = te.company_id
    -- On the whole-day clock the entry running now may be minutes old on a day that's hours long.
    where te.ended_at is null and (te.started_at < now() - interval '1 hour' or coalesce(c.settings -> 'clock' ->> 'mode' = 'day', false))
    for update of te skip locked
  loop
    -- How long they've been on the clock: this entry, or on the whole-day clock the run it ends.
    v_since := case when r.whole_day then coalesce(private.clock_run_start(r.id), r.started_at) else r.started_at end;
    continue when v_since >= now() - interval '1 hour';
    v_local := to_char(v_since at time zone coalesce(r.timezone, 'UTC'), 'FMHH12:MI AM');
    if v_since < now() - make_interval(secs => (r.stop_after * 3600)::int) then
      -- Stop it at the end of the working day it started on (or 8 hours in, if it started after that).
      v_end := ((r.started_at at time zone coalesce(r.timezone, 'UTC'))::date + r.day_end::time) at time zone coalesce(r.timezone, 'UTC');
      if v_end <= r.started_at then
        v_end := r.started_at + interval '8 hours';
      end if;
      if r.whole_day then
        -- The entry running now began well after the day did: never stopped later than now, nor before it began.
        v_end := greatest(least(v_end, now()), r.started_at + interval '1 second');
      end if;
      update public.time_entries set ended_at = v_end, auto_stopped_at = now() where id = r.id;
      insert into public.notifications (company_id, user_id, kind, title, body, link)
      values (r.company_id, r.user_id, 'time', 'Your clock was stopped for you',
              format(case when r.whole_day then 'It had been running since %s, so it was stopped at %s. Fix the end time on Timesheets if that''s wrong.'
                          else 'It started at %s and was still running, so it was stopped at %s. Fix the end time on Timesheets if that''s wrong.' end,
                     v_local, to_char(v_end at time zone coalesce(r.timezone, 'UTC'), 'FMHH12:MI AM Dy')),
              '/timesheets');
      v_stopped := v_stopped + 1;
    elsif v_since < now() - make_interval(secs => (r.remind_after * 3600)::int)
          -- Once for the entry, and on the whole-day clock once for the run.
          and not exists (select 1 from public.time_entries t2 where t2.company_id = r.company_id and t2.user_id = r.user_id and t2.reminded_at is not null
                          and (t2.id = r.id or (r.whole_day and t2.started_at >= v_since and t2.started_at <= r.started_at))) then
      update public.time_entries set reminded_at = now() where id = r.id;
      insert into public.notifications (company_id, user_id, kind, title, body, link)
      select r.company_id, who.user_id, 'time',
             case when who.user_id = r.user_id then 'Your clock is still running' else format('%s''s clock is still running', coalesce(nullif(p.full_name, ''), 'A crew member')) end,
             format(case when r.whole_day then 'On the clock since %s, %s hours ago. Stop it if the day is done.' else 'Started at %s, %s hours ago. Stop it if the day is done.' end,
                    v_local, floor(extract(epoch from now() - v_since) / 3600)),
             case when who.user_id = r.user_id then '/field' else '/timesheets' end
      from (
        select r.user_id
        union
        -- Their crew lead, who can stop it for them.
        select c.lead_user_id from public.crews c
        join public.crew_members cm on cm.crew_id = c.id
        where cm.user_id = r.user_id and c.company_id = r.company_id and c.active and c.lead_user_id is not null and c.lead_user_id <> r.user_id
      ) who
      left join public.profiles p on p.user_id = r.user_id;
      v_reminded := v_reminded + 1;
    end if;
  end loop;
  return jsonb_build_object('reminded', v_reminded, 'stopped', v_stopped);
end $$;
revoke execute on function public.clock_upkeep() from public, anon, authenticated;
grant execute on function public.clock_upkeep() to service_role;

notify pgrst, 'reload schema';
