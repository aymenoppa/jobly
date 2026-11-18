-- Closing or archiving a recurring job tells each person on its upcoming visits once.
--
-- A closed job's waiting visits come off the schedule (20261113000120_closed_jobs_leave_the_schedule.sql),
-- and with a crew's members on its visits a year ahead (20261113000210_visit_people.sql) a plain
-- delete was a line for every visit to everyone on the crew. They now go the way the schedule's own
-- removals do (public.remove_recurring_visits, 20261113000220_recurring_schedule_one_notice.sql):
-- quietly, with one line for each person who was on them. Which visits go is unchanged
-- (private.job_waiting_visits), and so is forgetting the skips a signed-in delete records, so a
-- reopened job gets its visits back.
create or replace function private.job_closed_drops_visits() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
  v_keys text[];
begin
  if new.status not in ('completed', 'archived') or new.status is not distinct from old.status then
    return null;
  end if;
  begin
    select array_agg(v.id), array_agg(v.recurrence_key) into v_ids, v_keys
    from public.visits v where v.id in (select private.job_waiting_visits(new.id));
    perform public.remove_recurring_visits(new.id, v_ids);
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
