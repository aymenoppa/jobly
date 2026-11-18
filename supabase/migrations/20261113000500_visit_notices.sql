-- Clients hear when a visit is booked, moved or cancelled.
--
-- Automations could remind a client the day before, say a crew was on the way, and answer a
-- client's own request to move or cancel from the Client Hub. Nothing told them when the office
-- booked a visit, moved one or took one off the schedule. Three events now start rules:
--
--   visit.scheduled    a visit or assessment goes on the schedule: a new one with a day, or one
--                      that had no day, or was cancelled, and gets one. Whoever books it: a person,
--                      an assistant, or the server acting on a booking (nobody has to be signed
--                      in). Not the visits a recurring job's schedule makes (a year of them), not a
--                      day in the past or a start time already gone by, not a visit created
--                      already under way or finished.
--   visit.rescheduled  a visit still to come moves to another day, or its start time moves by an
--                      hour or more. A later start still inside the arrival window the business
--                      gives its clients (Settings → Company) isn't a move, and neither is a visit
--                      gaining or losing its time on the same day: organizing a route re-times
--                      visits all day long, and the client was told the day and the window.
--   visit.cancelled    a visit still to come is cancelled, deleted or taken off the schedule.
--
-- Each is emitted here, by triggers on visits, so every way a visit changes is covered (the
-- schedule board, the visit's own form, a job's page, a rain day, an assistant, a phone catching
-- up after being offline), and only for a company with a rule on it turned on.
--
-- A client hears what matters once:
--
--   * Rules on these events run ten minutes after the change (private.visit_notice_settle), with
--     the visit as it is then. While a message waits, another change to the visit folds into it:
--     booked and then moved is one "booked" with the final time; moved twice is one "moved";
--     moved and moved back is nothing; booked and then cancelled is nothing; moved and then
--     cancelled is one "cancelled" naming the day the client knew.
--   * Multi-day work (visits.series_id) is one message: every day has its event, so each folds
--     its own changes as above, and when the rules run only the first day's goes
--     (public.visit_notice_is_repeat, asked by the engine before it sends).
--   * Never while the server changes a recurring job's whole run of visits or takes a closed job's
--     visits off (private.schedule_quiet), never for imports (jobly.quiet), never for a deleted
--     recurring job's visits, never for an archived client, and never for the change that answers
--     the client's own request from the Hub, which sends its own answer (services/visitChanges.ts).
--
-- Server code that books for a client inserts the visit and gets visit.scheduled like anyone. If
-- it tells the client itself it calls public.call_off_visit_notice(visit) afterwards; to have the
-- message go at once instead of after the ten minutes, public.send_visit_notice_now(visit).
--
-- supabase/tests/visit_notices_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- Ten minutes for a change to settle
-- ---------------------------------------------------------------------------------------------

create function private.visit_notice_settle() returns interval
language sql immutable set search_path = '' as $$
  select interval '10 minutes'
$$;

create function private.is_visit_notice(p_verb text) returns boolean
language sql immutable set search_path = '' as $$
  select p_verb in ('visit.scheduled', 'visit.rescheduled', 'visit.cancelled')
$$;

-- As in 20261017000200_automations.sql, and a rule on a visit being booked, moved or cancelled
-- waits the settle time first.
create or replace function private.queue_automations() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.automation_runs (company_id, rule_id, activity_id, subject_type, subject_id, run_after)
  select r.company_id, r.id, new.id, new.subject_type, new.subject_id,
         now() + make_interval(mins => r.delay_minutes)
           + case when private.is_visit_notice(new.verb) then private.visit_notice_settle() else interval '0' end
  from public.automation_rules r
  where r.company_id = new.company_id and r.enabled and r.trigger = new.verb;
  return null;
end $$;

-- The runs of an event still waiting are looked up by the event.
create index automation_runs_waiting_activity_idx on public.automation_runs (activity_id) where status = 'pending';

-- ---------------------------------------------------------------------------------------------
-- What counts as a move
-- ---------------------------------------------------------------------------------------------

-- The arrival window a business gives its clients, as core's arrivalWindowMin reads it
-- (companies.settings.arrival_window_min, in minutes, at most 12 hours; none is no window).
create function private.arrival_window(p_settings jsonb) returns interval
language sql immutable set search_path = '' as $$
  select make_interval(mins => case
    when jsonb_typeof(p_settings -> 'arrival_window_min') = 'number' or (p_settings ->> 'arrival_window_min') ~ '^\s*[0-9]+(\.[0-9]+)?\s*$'
      then greatest(least(round((p_settings ->> 'arrival_window_min')::numeric), 720), 0)::integer
    else 0 end)
$$;

-- Whether a visit that was on p_was_day (starting p_was_start, if it had a time) is somewhere else
-- for its client now: another day, or a start an hour or more away. A later start still inside the
-- arrival window they were given is where they were told, and so is a time gained or lost on the
-- same day.
create function private.visit_moved(p_was_day date, p_was_start timestamptz, p_day date, p_start timestamptz, p_window interval) returns boolean
language sql stable set search_path = '' as $$
  select p_was_day is distinct from p_day
      or (p_was_start is not null and p_start is not null
          and not (p_start >= p_was_start and p_start <= p_was_start + coalesce(p_window, interval '0'))
          and (p_start >= p_was_start + interval '1 hour' or p_start <= p_was_start - interval '1 hour'))
$$;

-- ---------------------------------------------------------------------------------------------
-- The message still waiting about a visit
-- ---------------------------------------------------------------------------------------------

-- The latest of the three events about a visit whose rules haven't run yet (nothing: all nulls).
create function private.unsent_visit_notice(p_visit uuid, out activity_id bigint, out verb text, out data jsonb)
language sql stable security definer set search_path = '' as $$
  select a.id, a.verb, a.data
  from public.activity a
  where a.subject_type = 'visit' and a.subject_id = p_visit and private.is_visit_notice(a.verb)
    and exists (select 1 from public.automation_runs r where r.activity_id = a.id and r.status = 'pending')
  order by a.id desc
  limit 1
$$;

-- Call off an event's runs that haven't started. Returns how many.
create function private.call_off_visit_notice(p_activity bigint, p_why text) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  update public.automation_runs
     set status = 'cancelled', finished_at = now(), error = p_why
   where activity_id = p_activity and status = 'pending';
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------------------------
-- A visit is booked, moved or comes off the schedule
-- ---------------------------------------------------------------------------------------------

create function private.visit_notice() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v public.visits;          -- the visit as it is now; as it was, for one deleted
  v_today date;
  v_window interval;
  v_client uuid;
  v_was_on boolean;         -- it was on the schedule
  v_is_on boolean;          -- it's on the schedule, today or later
  v_change text;            -- booked, moved or off
  v_unsent record;          -- the message about it still waiting, if any
  v_was_day date;           -- where the client last knew it to be
  v_was_start timestamptz;
  v_verb text;
begin
  if private.schedule_quiet() or coalesce(current_setting('jobly.quiet', true), '') = 'on' then
    return null;
  end if;
  if tg_op = 'DELETE' then v := old; else v := new; end if;
  if v.kind not in ('job', 'assessment') then return null; end if;
  select private.company_today(c.id), private.arrival_window(c.settings) into v_today, v_window
  from public.companies c where c.id = v.company_id;
  if not found then return null; end if; -- the whole company is being deleted

  v_was_on := tg_op <> 'INSERT' and old.status = 'scheduled' and old.scheduled_on is not null;
  v_is_on := tg_op <> 'DELETE' and new.status = 'scheduled' and new.scheduled_on is not null and new.scheduled_on >= v_today;
  if v_is_on and not v_was_on then
    -- New with a day, or given one after having none or being cancelled. Not the visits a recurring
    -- job's schedule makes, and not a visit a crew stepped back from "on my way" or reopened.
    if tg_op = 'INSERT' then
      if new.recurrence_key is not null then return null; end if;
    elsif old.status not in ('unscheduled', 'cancelled', 'scheduled') then
      return null;
    end if;
    v_change := 'booked';
  elsif v_is_on and v_was_on then
    v_change := 'moved';
  elsif v_was_on and old.scheduled_on >= v_today
        and (tg_op = 'DELETE' or new.status in ('cancelled', 'unscheduled') or new.scheduled_on is null) then
    -- A recurring job that's deleted takes a year of visits with it: no message for each, as when
    -- one is closed (private.job_closed_drops_visits).
    if tg_op = 'DELETE' and old.recurrence_key is not null and old.job_id is not null
       and not exists (select 1 from public.jobs j where j.id = old.job_id) then
      return null;
    end if;
    v_change := 'off';
  else
    return null; -- started, finished, or moved into the past
  end if;

  v_client := private.visit_client(v);
  if v_client is null or exists (select 1 from public.clients c where c.id = v_client and c.status = 'archived') then
    return null;
  end if;
  select * into v_unsent from private.unsent_visit_notice(v.id);

  -- The change that answers the client's own request from the Hub: they get that answer
  -- (services/visitChanges.ts), not this as well.
  if tg_op = 'UPDATE' and v_change in ('moved', 'off') and exists (
    select 1 from public.visit_change_requests q
    where q.visit_id = v.id and q.status = 'approved' and q.decided_at > now() - interval '2 minutes'
      and case when v_change = 'off' then q.kind = 'cancel' else q.kind = 'reschedule' and q.scheduled_on = new.scheduled_on end
  ) then
    if v_unsent.activity_id is not null then
      perform private.call_off_visit_notice(v_unsent.activity_id, 'The client was told when their request was approved');
    end if;
    return null;
  end if;

  if v_change = 'booked' then
    if v_unsent.verb = 'visit.cancelled' then
      -- Taken off and put back before the client heard: nothing if it's back where it was, else a move.
      perform private.call_off_visit_notice(v_unsent.activity_id, 'The visit went back on the schedule before this went out');
      v_was_day := (v_unsent.data ->> 'was_scheduled_on')::date;
      v_was_start := (v_unsent.data ->> 'was_starts_at')::timestamptz;
      if not private.visit_moved(v_was_day, v_was_start, new.scheduled_on, new.starts_at, v_window) then return null; end if;
      v_verb := 'visit.rescheduled';
    elsif v_unsent.activity_id is not null then
      return null;
    elsif new.starts_at is not null and new.starts_at <= now() then
      return null; -- put on the schedule after it began: work written down afterwards
    else
      v_verb := 'visit.scheduled';
    end if;
  elsif v_change = 'moved' then
    if v_unsent.verb = 'visit.rescheduled' then
      -- The message waiting will say where it is by then. Back where the client knew it: no message.
      if not private.visit_moved((v_unsent.data ->> 'was_scheduled_on')::date, (v_unsent.data ->> 'was_starts_at')::timestamptz, new.scheduled_on, new.starts_at, v_window) then
        perform private.call_off_visit_notice(v_unsent.activity_id, 'The visit went back to where it was');
      end if;
      return null;
    elsif v_unsent.activity_id is not null then
      return null; -- "booked" is waiting, and will say where it is by then
    elsif not private.visit_moved(old.scheduled_on, old.starts_at, new.scheduled_on, new.starts_at, v_window) then
      return null;
    end if;
    v_was_day := old.scheduled_on;
    v_was_start := old.starts_at;
    v_verb := 'visit.rescheduled';
  else
    v_was_day := old.scheduled_on;
    v_was_start := old.starts_at;
    if v_unsent.verb = 'visit.scheduled' then
      perform private.call_off_visit_notice(v_unsent.activity_id, 'The visit came off the schedule before this went out');
      return null; -- they never heard it was booked
    elsif v_unsent.verb = 'visit.rescheduled' then
      -- They never heard it moved: it's the day they knew that's cancelled.
      perform private.call_off_visit_notice(v_unsent.activity_id, 'The visit came off the schedule before this went out');
      v_was_day := (v_unsent.data ->> 'was_scheduled_on')::date;
      v_was_start := (v_unsent.data ->> 'was_starts_at')::timestamptz;
    elsif v_unsent.activity_id is not null then
      return null;
    end if;
    v_verb := 'visit.cancelled';
  end if;

  -- Only for a company with a rule on it turned on, as the day-before reminder is.
  if not exists (select 1 from public.automation_rules r where r.company_id = v.company_id and r.enabled and r.trigger = v_verb) then
    return null;
  end if;
  perform private.emit(v.company_id, v_verb, 'visit', v.id,
    format('%s: %s (%s)',
      case v_verb when 'visit.scheduled' then 'Visit booked' when 'visit.rescheduled' then 'Visit moved' else 'Visit cancelled' end,
      v.title, private.client_name(v_client)),
    jsonb_strip_nulls(jsonb_build_object('kind', v.kind, 'client_id', v_client, 'series_id', v.series_id, 'series_day', v.series_day)
      || case when v_verb = 'visit.scheduled' then '{}'::jsonb
              else jsonb_build_object('was_scheduled_on', v_was_day, 'was_starts_at', v_was_start) end
      -- What a message needs once the visit is gone.
      || case when v_verb = 'visit.cancelled'
              then jsonb_build_object('title', v.title, 'job_id', v.job_id, 'property_id', v.property_id, 'deleted', tg_op = 'DELETE')
              else '{}'::jsonb end));
  return null;
end $$;

create trigger client_notice_booked after insert on public.visits
  for each row when (new.recurrence_key is null and new.kind in ('job', 'assessment') and new.status = 'scheduled')
  execute function private.visit_notice();
create trigger client_notice_changed after update on public.visits
  for each row when (old.status is distinct from new.status or old.scheduled_on is distinct from new.scheduled_on or old.starts_at is distinct from new.starts_at)
  execute function private.visit_notice();
create trigger client_notice_deleted after delete on public.visits
  for each row when (old.status = 'scheduled' and old.kind in ('job', 'assessment'))
  execute function private.visit_notice();

-- The office moved a visit itself and then approved the client's request that named no time
-- ("tell us what suits you"): the approval's email says where the visit is now, so the "moved"
-- message still waiting is called off. A request with a time moves the visit as it's approved,
-- which private.visit_notice leaves to the approval too.
create function private.visit_change_approved_calls_off() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_unsent record;
begin
  select * into v_unsent from private.unsent_visit_notice(new.visit_id);
  if v_unsent.verb = 'visit.rescheduled' then
    perform private.call_off_visit_notice(v_unsent.activity_id, 'The client was told when their request was approved');
  end if;
  return null;
end $$;
create trigger approved_calls_off_notice after update of status on public.visit_change_requests
  for each row when (new.status = 'approved' and old.status is distinct from 'approved' and new.kind = 'reschedule' and new.scheduled_on is null)
  execute function private.visit_change_approved_calls_off();

-- ---------------------------------------------------------------------------------------------
-- Multi-day work is one message
-- ---------------------------------------------------------------------------------------------

-- Booking, moving or deleting multi-day work changes each of its days, and each day has its event
-- (so a day put back, or cancelled before anyone heard, folds as any visit's does). When a rule's
-- runs come due only one goes: the earliest day's, among the same rule's runs for the same work
-- and the same kind of change from around the same time that are waiting, running or done. The
-- engine asks this before a run about a visit being booked, moved or cancelled does anything; true
-- means another day's run says it for the work.
create function public.visit_notice_is_repeat(p_run bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.automation_runs r
    join public.activity a on a.id = r.activity_id
    join public.automation_runs o
      on o.rule_id = r.rule_id and o.id <> r.id and o.status in ('pending', 'running', 'done')
     and o.created_at between r.created_at - private.visit_notice_settle() and r.created_at + private.visit_notice_settle()
    join public.activity b on b.id = o.activity_id
    where r.id = p_run and private.is_visit_notice(a.verb) and a.data ? 'series_id'
      and b.verb = a.verb and b.company_id = a.company_id and b.data ->> 'series_id' = a.data ->> 'series_id'
      and (coalesce((b.data ->> 'series_day')::integer, 0), o.id) < (coalesce((a.data ->> 'series_day')::integer, 0), r.id)
  )
$$;

-- ---------------------------------------------------------------------------------------------
-- For the server, when it books or changes a visit for a client
-- ---------------------------------------------------------------------------------------------

-- The server told the client itself (a booking page's own confirmation): the message still
-- waiting about this visit doesn't go. Returns how many runs it called off.
create function public.call_off_visit_notice(p_visit uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  update public.automation_runs r
     set status = 'cancelled', finished_at = now(), error = 'The client was told another way'
    from public.activity a
   where a.id = r.activity_id and a.subject_type = 'visit' and a.subject_id = p_visit and private.is_visit_notice(a.verb)
     and r.status = 'pending';
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- The client is waiting to hear (they just booked online): the message still waiting about this
-- visit goes on the next pass instead of after the ten minutes. Returns how many runs it moved up.
create function public.send_visit_notice_now(p_visit uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  update public.automation_runs r
     set run_after = now()
    from public.activity a
   where a.id = r.activity_id and a.subject_type = 'visit' and a.subject_id = p_visit and private.is_visit_notice(a.verb)
     and r.status = 'pending' and r.run_after > now();
  get diagnostics v_count = row_count;
  return v_count;
end $$;

revoke all on function private.visit_notice_settle(), private.is_visit_notice(text), private.arrival_window(jsonb),
  private.visit_moved(date, timestamptz, date, timestamptz, interval), private.unsent_visit_notice(uuid),
  private.call_off_visit_notice(bigint, text),
  private.visit_notice(), private.visit_change_approved_calls_off() from public;
revoke execute on function public.call_off_visit_notice(uuid), public.send_visit_notice_now(uuid), public.visit_notice_is_repeat(bigint) from public, anon, authenticated;
grant execute on function public.call_off_visit_notice(uuid), public.send_visit_notice_now(uuid), public.visit_notice_is_repeat(bigint) to service_role;

notify pgrst, 'reload schema';
