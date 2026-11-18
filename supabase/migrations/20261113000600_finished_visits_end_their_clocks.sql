-- Finishing a visit ends every clock still running on it.
--
-- One clock runs per person, and Complete visit stopped only the clock of whoever tapped it (the
-- field app did that itself, after the tap). A crewmate clocked in on the same visit who didn't tap
-- Complete had no button left once it was finished: their clock kept running against the finished
-- visit until they started the next one, so the drive there was counted as time on the last job.
--
-- Now the database ends them, whoever finishes the visit and from wherever (the field app, the
-- schedule, an assistant, a tap sent later from a phone that had no signal, a phone still on the
-- previous app version):
--
--   When        Each clock ends at the moment the visit was finished: visits.completed_at, which
--               for a Complete tapped with no signal is when it was tapped, not when it arrived.
--               A clock that started after that moment (a crewmate clocked in while the tap was
--               still waiting on a phone) ends when the finish arrives instead, so no clock ends
--               before it began. A visit finished a second time (reopened, then completed again)
--               keeps its first date, so its clocks end now.
--   Late        A clock-in on the visit that arrives after it was finished, dated before it was
--   clock-ins   (a crewmate's Start tapped with no signal), ends at that moment too.
--   Not over    A clock never ends past the start of later time the person already has.
--   other time
--   Locked      Time that's approved, or on a day the person has been marked paid for, isn't
--   time        touched (private.paid_for, as private.paid_time_guard locks it).
--
-- The field app still stops the clock of whoever taps Complete, first, because that's where the
-- phone's place comes from; this ends everyone else's. A problem with one clock never holds up the
-- tap or the other clocks (it's noted as a warning), as with private.visit_finishes_job.
--
-- Clocks already running on finished visits are left as they are: the hourly upkeep reminds their
-- owners and stops them (public.clock_upkeep), marked for the office to check.
--
-- supabase/tests/finished_visit_clocks_test.sql covers it.

-- One clock still running on a visit that was finished at p_at.
create function private.finished_visit_clock(p_entry uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = '' as $$
declare
  e public.time_entries;
  v_tz text;
  v_end timestamptz;
  v_next timestamptz;
begin
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
end $$;

create function private.visit_finished_clocks() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  -- When it was finished: the date this change gave it, or now for a visit that had one already.
  v_at timestamptz := least(case when old.completed_at is null then coalesce(new.completed_at, now()) else now() end, now());
  v_entry uuid;
begin
  for v_entry in
    select t.id from public.time_entries t where t.company_id = new.company_id and t.visit_id = new.id and t.ended_at is null
  loop
    begin
      perform private.finished_visit_clock(v_entry, v_at);
    exception when others then
      raise warning 'ending a clock on a finished visit: %', sqlerrm;
    end;
  end loop;
  return null;
end $$;
create trigger finished_clocks after update of status on public.visits
  for each row when (new.status = 'completed' and old.status is distinct from 'completed')
  execute function private.visit_finished_clocks();

-- A clock-in that arrives after its visit was finished, dated before it was.
create function private.clock_on_finished_visit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_done timestamptz;
begin
  select v.completed_at into v_done from public.visits v where v.id = new.visit_id and v.company_id = new.company_id and v.status = 'completed';
  if v_done > new.started_at then
    begin
      perform private.finished_visit_clock(new.id, least(v_done, now()));
    exception when others then
      raise warning 'ending a clock on a finished visit: %', sqlerrm;
    end;
  end if;
  return null;
end $$;
create trigger finished_visit after insert on public.time_entries
  for each row when (new.visit_id is not null and new.ended_at is null)
  execute function private.clock_on_finished_visit();

revoke all on function private.finished_visit_clock(uuid, timestamptz), private.visit_finished_clocks(), private.clock_on_finished_visit() from public;

notify pgrst, 'reload schema';
