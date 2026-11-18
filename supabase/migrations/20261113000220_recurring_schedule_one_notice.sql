-- A recurring job's whole schedule changing is one line for each person, not one for every visit.
--
-- Recurring visits are on the schedule a year ahead and, with nobody listed, their crew is on them
-- (20261113000210_visit_people.sql): changing a job's time or crew with "Change the upcoming visits
-- too", a new repeat, or pausing it would be a line for every visit to everyone on the crew. The
-- server's two changes (tasks.ts, materializeJob) are made with the schedule's notification
-- triggers quiet, and each person on those visits before or after hears once:
-- public.refresh_upcoming_visits, and the new public.remove_recurring_visits.

create function private.recurring_change_notify(p_job public.jobs, p_people uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
declare u uuid;
begin
  for u in select distinct x from unnest(p_people) x loop
    perform private.notify_schedule(p_job.company_id, u, null, format('The upcoming visits for job #%s (%s) changed', p_job.number, p_job.title));
  end loop;
end $$;

-- As in 20261107000400_refresh_upcoming_visits.sql, quietly, and telling the people on them once
-- when a time or the crew changed (a new title alone isn't a change to anyone's day).
create or replace function public.refresh_upcoming_visits(p_job uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
  v_job public.jobs;
  v_today date;
  v_quiet text := coalesce(current_setting('jobly.schedule_quiet', true), '');
  v_people uuid[];
  v_after uuid[];
  v_was text;
  v_now text;
begin
  select * into v_job from public.jobs where id = p_job;
  if not found then return 0; end if;
  v_today := private.company_today(v_job.company_id);
  select coalesce(array_agg(distinct p.user_id), '{}'), md5(coalesce(string_agg(concat_ws(' ', v.id, v.starts_at, v.crew_id), ',' order by v.id), ''))
  into v_people, v_was
  from public.visits v left join lateral private.visit_people(v.id) as p(user_id) on true
  where v.job_id = p_job and v.status = 'scheduled' and v.recurrence_key is not null and v.scheduled_on >= v_today;

  perform set_config('jobly.schedule_quiet', 'on', true);
  update public.visits v set
    title = j.title,
    crew_id = j.default_crew_id,
    starts_at = private.zoned_time(v.scheduled_on, j.visit_start_time, c.tz),
    ends_at = private.zoned_time(v.scheduled_on, j.visit_start_time, c.tz) + make_interval(mins => j.visit_duration_min),
    time_fixed = j.visit_start_time is not null and j.visit_time_fixed
  from public.jobs j
  cross join lateral (select coalesce(timezone, 'UTC') as tz from public.companies where id = j.company_id) c
  where j.id = p_job and v.job_id = j.id
    and v.status = 'scheduled' and v.recurrence_key is not null
    and v.scheduled_on >= private.company_today(j.company_id);
  get diagnostics v_count = row_count;
  perform set_config('jobly.schedule_quiet', v_quiet, true);

  select coalesce(array_agg(distinct p.user_id), '{}'), md5(coalesce(string_agg(concat_ws(' ', v.id, v.starts_at, v.crew_id), ',' order by v.id), ''))
  into v_after, v_now
  from public.visits v left join lateral private.visit_people(v.id) as p(user_id) on true
  where v.job_id = p_job and v.status = 'scheduled' and v.recurrence_key is not null and v.scheduled_on >= v_today;
  if v_was is distinct from v_now and not private.schedule_quiet() then
    perform private.recurring_change_notify(v_job, v_people || v_after);
  end if;
  return v_count;
end $$;

/**
 * The server's (materializeJob): take a recurring job's waiting visits off the schedule when its
 * repeat no longer has their dates, or while it's paused. Only this job's recurring visits still
 * waiting; the server has already left out the ones with work logged or pay agreed. The people who
 * were on them hear once. Returns how many it removed.
 */
create function public.remove_recurring_visits(p_job uuid, p_visits uuid[]) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
  v_job public.jobs;
  v_quiet text := coalesce(current_setting('jobly.schedule_quiet', true), '');
  v_people uuid[];
begin
  select * into v_job from public.jobs where id = p_job;
  if not found or coalesce(cardinality(p_visits), 0) = 0 then return 0; end if;
  select coalesce(array_agg(distinct p.user_id), '{}') into v_people
  from public.visits v cross join lateral private.visit_people(v.id) as p(user_id)
  where v.id = any (p_visits) and v.job_id = p_job and v.status = 'scheduled' and v.recurrence_key is not null
    and v.scheduled_on >= private.company_today(v_job.company_id);

  perform set_config('jobly.schedule_quiet', 'on', true);
  delete from public.visits v
  where v.id = any (p_visits) and v.job_id = p_job and v.status = 'scheduled' and v.recurrence_key is not null;
  get diagnostics v_count = row_count;
  perform set_config('jobly.schedule_quiet', v_quiet, true);

  if v_count > 0 and not private.schedule_quiet() then
    perform private.recurring_change_notify(v_job, v_people);
  end if;
  return v_count;
end $$;
revoke execute on function public.remove_recurring_visits(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.remove_recurring_visits(uuid, uuid[]) to service_role;

revoke all on function private.recurring_change_notify(public.jobs, uuid[]) from public;

notify pgrst, 'reload schema';
