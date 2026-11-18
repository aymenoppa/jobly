-- Closing or archiving a job takes its waiting visits off the schedule.
--
-- Pausing a recurring job already did (tasks.ts materializeJob), but closing one (completed) or
-- archiving it didn't: the nightly run stopped making visits and left up to 60 days of them on the
-- board, for crews to drive to.
--
-- Now a job that becomes completed or archived loses the visits its schedule made that are still
-- to come and that nobody has touched, the same visits a pause takes off: made by the schedule
-- (recurrence_key), still 'scheduled', today or later where the company is, with no time, materials
-- or checklist answers logged on them and no job pay whose work is done or paid covering them.
-- Whatever closes it: the job's page, the Jobs list, an invoice (create_invoice_for_job), an
-- assistant, or a browser still running the previous version.
--
-- A visit someone added by hand stays: nothing would bring it back, and an invoice closes a job
-- without asking. Visits removed here aren't remembered as deleted (recurrence_skips), so a job
-- reopened gets them again from the nightly run, as a resumed one does.
--
-- job_visits_to_remove tells the job's page how many will go, for its question.
--
-- supabase/tests/closed_jobs_test.sql covers it.

-- The visits a closed job loses, as materializeJob's prune picks them.
create function private.job_waiting_visits(p_job uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select v.id
  from public.visits v
  where v.job_id = p_job and v.status = 'scheduled' and v.recurrence_key is not null
    and v.scheduled_on >= private.company_today(v.company_id)
    and not exists (select 1 from public.job_pay_visits pv join public.job_pay p on p.id = pv.job_pay_id
                    where pv.visit_id = v.id and p.status in ('done', 'paid'))
    and not exists (select 1 from public.time_entries t where t.visit_id = v.id)
    and not exists (select 1 from public.job_materials m where m.visit_id = v.id)
    and not exists (select 1 from public.checklist_responses r where r.visit_id = v.id)
$$;

-- How many visits closing or archiving a job would remove, for the people who can do either.
create function public.job_visits_to_remove(p_job uuid) returns integer
language sql stable security definer set search_path = '' as $$
  select case when exists (select 1 from public.jobs j where j.id = p_job and private.has_role(j.company_id, '{owner,admin,office,estimator}'))
    then (select count(*)::integer from private.job_waiting_visits(p_job)) else 0 end
$$;

-- A problem taking them off never stops the job from closing (an invoice being made closes it):
-- it's noted as a warning and the visits stay, as they did before.
create function private.job_closed_drops_visits() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_keys text[];
begin
  if new.status not in ('completed', 'archived') or new.status is not distinct from old.status then
    return null;
  end if;
  begin
    with gone as (
      delete from public.visits v where v.id in (select private.job_waiting_visits(new.id)) returning v.recurrence_key
    )
    select array_agg(recurrence_key) into v_keys from gone;
    -- A person closing the job is signed in, so each visit was remembered as one they deleted
    -- (private.remember_deleted_occurrence). They didn't: forget the ones just made, so the schedule
    -- makes these visits again if the job is reopened.
    delete from public.recurrence_skips s
    where s.job_id = new.id and s.recurrence_key = any (v_keys) and s.deleted_at = now();
  exception when others then
    raise warning 'taking a closed job''s visits off: %', sqlerrm;
  end;
  return null;
end $$;
create trigger closed_drops_visits after update on public.jobs
  for each row execute function private.job_closed_drops_visits();

revoke all on function private.job_waiting_visits(uuid), private.job_closed_drops_visits() from public;
revoke execute on function public.job_visits_to_remove(uuid) from public, anon;
grant execute on function public.job_visits_to_remove(uuid) to authenticated;

notify pgrst, 'reload schema';
