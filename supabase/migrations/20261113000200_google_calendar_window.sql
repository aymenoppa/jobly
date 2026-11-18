-- The visits calendar on Google covers the next six months (integrations/calendars.ts), and every
-- change to a visit queued a push of its own, whatever its date. That was fine while a recurring
-- job's visits were made 60 days ahead. Made a year ahead (tasks.ts, VISIT_HORIZON_DAYS), the first
-- night would queue thousands of pushes at once, holding up invoices on their way to the books
-- behind them for hours, and fill the calendar a year out.
--
-- So a recurring job's visit past the days the calendar covers isn't queued: not when it's made,
-- changed or removed. The nightly task sends each as it comes within the six months, in one batch,
-- and keeps the last day it has covered in the connection's settings (visits_through). A visit
-- someone books by hand goes across when it's booked, whatever its date, as before.

create or replace function private.enqueue_calendar_push() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_company uuid := coalesce(new.company_id, old.company_id);
  v_visit uuid := coalesce(new.id, old.id);
  v_settings jsonb;
  -- Days as text (YYYY-MM-DD sorts as dates do), so a setting that isn't a date can't stop a visit being saved.
  v_through text := to_char(current_date + 180, 'YYYY-MM-DD');
  v_new text := case when tg_op <> 'DELETE' then to_char(new.scheduled_on, 'YYYY-MM-DD') end;
  v_old text := case when tg_op <> 'INSERT' then to_char(old.scheduled_on, 'YYYY-MM-DD') end;
begin
  if tg_op = 'UPDATE' and (new.title, new.kind, new.scheduled_on, new.starts_at, new.ends_at, new.status, new.crew_id, new.notes, new.property_id, new.job_id)
    is not distinct from (old.title, old.kind, old.scheduled_on, old.starts_at, old.ends_at, old.status, old.crew_id, old.notes, old.property_id, old.job_id) then
    return null;
  end if;
  -- A company being deleted takes its visits with it; nothing to tell Google.
  if tg_op = 'DELETE' and not exists (select 1 from public.companies where id = v_company) then
    return null;
  end if;
  select settings into v_settings from public.integrations
  where company_id = v_company and provider = 'google_calendar' and status = 'connected' and settings ? 'push_calendar_id';
  if not found then
    return null;
  end if;
  -- A recurring job's visit past the days the calendar covers waits for the nightly task. One that
  -- moves into those days, or out of them, still goes now.
  if coalesce(case when tg_op <> 'DELETE' then new.recurrence_key end, case when tg_op <> 'INSERT' then old.recurrence_key end) is not null
     and coalesce(v_new, v_old) is not null then
    if v_settings ->> 'visits_through' ~ '^\d{4}-\d{2}-\d{2}$' and (v_settings ->> 'visits_through') collate "C" < v_through then
      v_through := v_settings ->> 'visits_through';
    end if;
    if (v_new is null or v_new collate "C" > v_through) and (v_old is null or v_old collate "C" > v_through) then
      return null;
    end if;
  end if;
  if exists (
    select 1 from public.outbox
    where company_id = v_company and topic = 'calendar.visit' and payload ->> 'visit_id' = v_visit::text
      and done_at is null and dead_at is null and (locked_until is null or locked_until < now())
  ) then
    return null;
  end if;
  insert into public.outbox (company_id, topic, payload) values (v_company, 'calendar.visit', jsonb_build_object('visit_id', v_visit));
  return null;
end $$;

-- Companies already putting visits on Google have the next 60 days of recurring visits there. The
-- rest of the six months follows on the first night, as one batch (a day's overlap does no harm).
update public.integrations
set settings = settings || jsonb_build_object('visits_through', to_char(current_date + 59, 'YYYY-MM-DD'))
where provider = 'google_calendar' and settings ? 'push_calendar_id' and not settings ? 'visits_through';
