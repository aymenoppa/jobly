-- A visit that moves to another day after its day-before reminder went is reminded for its new day.
--
-- emit_visit_reminders gave each visit one reminder, ever: it skipped any visit that already had a
-- visit.reminder event. A visit reminded on Monday for Tuesday and then moved to Friday got nothing
-- on Thursday. The event has always kept the day it was for (data.scheduled_on), so the check now
-- goes by it: one reminder for each day a visit is on. Moved to another day, it's due again the
-- day before that day; changed in time only, or moved away and back, it isn't.
--
-- Reminders still go from 8 in the morning the day before, where the company is, and the hourly
-- task still looks. So a visit moved onto tomorrow later than that (at 3pm, say) gets its reminder
-- at the next look, within the hour, rather than never.
--
-- The engine holds a reminder back when the visit has left that day, or the schedule, between the
-- event and the email (services/automations.ts reminderSkip).
--
-- supabase/tests/visit_reminders_test.sql covers it.

-- As in 20261017000200_automations.sql, except a reminder for another day doesn't count. An event
-- that kept no day (none do, but nothing made them) counts for whatever day the visit is on.
create or replace function public.emit_visit_reminders() returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  with due as (
    select v.id, v.company_id, v.title, v.scheduled_on, private.visit_client(v) as client_id
    from public.visits v
    join public.companies c on c.id = v.company_id
    where v.status = 'scheduled'
      and v.kind in ('job', 'assessment')
      and v.scheduled_on = ((now() at time zone c.timezone)::date + 1)
      and extract(hour from now() at time zone c.timezone) >= 8 -- sent in the morning, not at midnight
      and exists (select 1 from public.automation_rules r where r.company_id = v.company_id and r.enabled and r.trigger = 'visit.reminder')
      and not exists (select 1 from public.activity a where a.subject_id = v.id and a.verb = 'visit.reminder'
                        and coalesce(a.data ->> 'scheduled_on', v.scheduled_on::text) = v.scheduled_on::text)
  )
  insert into public.activity (company_id, actor_id, verb, subject_type, subject_id, summary, data)
  select d.company_id, null, 'visit.reminder', 'visit', d.id, 'Reminder due: ' || d.title,
         jsonb_build_object('client_id', d.client_id, 'scheduled_on', d.scheduled_on)
  from due d where d.client_id is not null;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

notify pgrst, 'reload schema';
