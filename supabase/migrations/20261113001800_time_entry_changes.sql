-- Every change to a worker's time is on record.
--
-- The office (and a crew lead, for their crew) can change or delete anyone's time, and until now
-- an edit was an in-place update: nothing kept what the entry said before, who changed it or why,
-- and the worker wasn't told. An employer has to keep the hours each person worked (29 CFR
-- 516.2(a)(7), for three years: 516.5), and with no record of an edit can't show that a shortened
-- entry was a correction.
--
--   time_entry_changes   One row per change, written by a trigger on time_entries and by nothing
--                        else: time added for someone by somebody else, every update that changes
--                        the start, end, type (a break is a type), visit, job or note, and every
--                        delete. It keeps who was signed in, when, the old and new values, why if
--                        a reason was given, and what did it (`source`):
--
--                          person          someone's own tap or edit (Timesheets, the clock card)
--                          assistant       an AI assistant connected to their account
--                          geofence        the phone, at the property (the clock at the property)
--                          finished_visit  completing a visit, which ends the clocks still on it
--                          next_clock      starting another clock, which ends the one running
--                          auto_stop       the hourly upkeep stopping a clock left running
--                          sub_off_clock   a subcontractor taken off the clock or off a visit
--                          system          anything else the database or the server did (a deleted
--                                          visit or job coming off the entry, a removed sign-in)
--
--                        A person's own clock-in, or time they add for themselves, is not a
--                        change: the entry is its own record. Approving isn't one either (the
--                        entry keeps who approved it and when).
--
--                        `edit` tells an edit from the clock simply running its course. A running
--                        clock stopped, or moved to other work, with its start untouched is the
--                        clock (a tap, or one of the database's own stops above): most entries
--                        have one of those and Timesheets doesn't flag them. Everything else is an
--                        edit: time added for someone, a start moved, a finished entry changed,
--                        anything Timesheets sends as an edit, and every delete.
--
-- Nobody signed in can add, edit or delete a row, and nobody at all can edit one. Rows go only
-- with their company. They outlive the entry (a deleted entry's history is the point), so
-- `entry_id` and the people are plain ids, not references.
--
-- The worker reads the changes to their own time; the office reads everyone's and a crew lead
-- their crew's, exactly as each reads the time itself (time_entries_read). When someone else
-- changes the times or type of a finished entry, moves its start, or deletes it, the worker gets a
-- notification on the bell (kind 'time', in Spanish for someone who reads the app in Spanish:
-- packages/core/src/i18n/es/notices.ts). A crew lead or the office stopping a running clock for
-- them with a tap is recorded but not announced, so the crew clock doesn't ring every phone at the
-- end of the day; an edit from Timesheets says it's an edit (a reason, even an empty one) and is.
--
-- Why: the web app sends `change_reason` with the write (an insert or an update), or calls
-- delete_time_entry(entry, reason). The column never keeps anything: a trigger takes it off the row
-- and hands it to the record. An app from before this sends none, and its changes are recorded
-- without a reason.
--
-- supabase/tests/time_entry_changes_test.sql covers it.

alter table public.time_entries
  add column change_reason text check (change_reason is null or length(change_reason) <= 300);
comment on column public.time_entries.change_reason is
  'Write-only: why this write changes the entry. Moved to time_entry_changes.reason by a trigger and never kept here';

create table public.time_entry_changes (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  -- Not references: the record outlives a deleted entry, and a person who has left.
  entry_id uuid not null,
  user_id uuid not null,
  action text not null check (action in ('added', 'changed', 'deleted')),
  changed_by uuid,
  source text not null,
  reason text,
  old_started_at timestamptz,
  new_started_at timestamptz,
  old_ended_at timestamptz,
  new_ended_at timestamptz,
  old_category text,
  new_category text,
  old_visit_id uuid,
  new_visit_id uuid,
  old_job_id uuid,
  new_job_id uuid,
  old_notes text,
  new_notes text,
  edit boolean not null,
  -- When the entry starts now (or started, once deleted): which week of Timesheets the change belongs to.
  entry_started_at timestamptz not null,
  -- The clock's time, not the transaction's: two changes made in one transaction keep their order.
  changed_at timestamptz not null default clock_timestamp()
);
comment on table public.time_entry_changes is 'Add-only record of every change to a time entry (written by the time_entry_changed trigger)';
comment on column public.time_entry_changes.user_id is 'Whose time it is';
comment on column public.time_entry_changes.changed_by is 'Who was signed in; null when the server did it by itself';
comment on column public.time_entry_changes.edit is 'False for a running clock stopped or moved with its start untouched (the clock running its course); true for everything else';
comment on column public.time_entry_changes.source is 'What did it: person, assistant, geofence, finished_visit, next_clock, auto_stop, sub_off_clock or system';
create index time_entry_changes_entry_idx on public.time_entry_changes (entry_id, changed_at);
create index time_entry_changes_user_idx on public.time_entry_changes (company_id, user_id, changed_at desc);
-- A week of edits for Timesheets.
create index time_entry_changes_week_idx on public.time_entry_changes (company_id, entry_started_at) where edit;

alter table public.time_entry_changes enable row level security;
-- As time_entries_read (20261017002100_crew_leads.sql) and time_entries_sub_read (a sub on the clock).
create policy time_entry_changes_read on public.time_entry_changes for select to authenticated using (
  (user_id = (select auth.uid()) and (private.is_member(company_id) or company_id = any ((select private.sub_clock_companies())::uuid[])))
  or private.has_role(company_id, '{owner,admin,office}')
  or (private.has_role(company_id, '{crew_lead}') and private.on_my_crew(company_id, user_id))
);
-- No other policy: only the trigger writes here.
revoke all on public.time_entry_changes from anon;
revoke insert, update, delete, truncate on public.time_entry_changes from authenticated;

-- A record isn't edited by anyone, the server included, and goes only with its company.
create function private.time_entry_changes_keep() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    raise exception 'A change to someone''s time is a record: it can''t be edited.' using errcode = '42501';
  end if;
  if exists (select 1 from public.companies c where c.id = old.company_id) then
    raise exception 'A change to someone''s time is a record: it can''t be deleted.' using errcode = '42501';
  end if;
  return old;
end $$;
revoke all on function private.time_entry_changes_keep() from public;
create trigger keep before update or delete on public.time_entry_changes
  for each row execute function private.time_entry_changes_keep();

-- ---------------------------------------------------------------------------------------------
-- Why: taken off the row as it's written, and handed to the record
-- ---------------------------------------------------------------------------------------------

-- The reasons given in this transaction, by entry: {"<entry id>": "<reason, or '' for none>"}.
create function private.time_change_reason_in() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.change_reason is not null then
    perform set_config('jobly.time_change_reasons',
      (coalesce(nullif(current_setting('jobly.time_change_reasons', true), ''), '{}')::jsonb
        || jsonb_build_object(new.id::text, btrim(new.change_reason)))::text, true);
    new.change_reason := null;
  end if;
  return new;
end $$;
revoke all on function private.time_change_reason_in() from public;
create trigger change_reason_in before insert or update on public.time_entries
  for each row execute function private.time_change_reason_in();

-- Deleting with a reason. It deletes as the person calling (the same policies and guards as a
-- plain delete), and says whether there was an entry of theirs to delete.
create function public.delete_time_entry(p_entry uuid, p_reason text default null) returns boolean
language plpgsql set search_path = '' as $$
declare
  v_count integer;
begin
  if p_entry is null then
    return false;
  end if;
  perform set_config('jobly.time_change_reasons',
    (coalesce(nullif(current_setting('jobly.time_change_reasons', true), ''), '{}')::jsonb
      || jsonb_build_object(p_entry::text, left(btrim(coalesce(p_reason, '')), 300)))::text, true);
  delete from public.time_entries where id = p_entry;
  get diagnostics v_count = row_count;
  return v_count > 0;
end $$;
revoke all on function public.delete_time_entry(uuid, text) from public, anon;
grant execute on function public.delete_time_entry(uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- The record, and telling the worker
-- ---------------------------------------------------------------------------------------------

create function private.time_entry_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_row public.time_entries := coalesce(new, old);
  v_by uuid := (select auth.uid());
  v_reasons jsonb := coalesce(nullif(current_setting('jobly.time_change_reasons', true), ''), '{}')::jsonb;
  v_given boolean;
  v_reason text;
  v_stack text;
  v_source text;
  v_edit boolean;
  v_tz text;
  v_body text;
begin
  -- Why, if this write said: once, for this entry.
  v_given := v_reasons ? v_row.id::text;
  if v_given then
    v_reason := nullif(v_reasons ->> v_row.id::text, '');
    perform set_config('jobly.time_change_reasons', (v_reasons - v_row.id::text)::text, true);
  end if;

  if tg_op = 'INSERT' then
    -- Their own clock-in, or time they added for themselves: the entry is the record.
    if v_by is not null and v_by = new.user_id then
      return null;
    end if;
  elsif tg_op = 'UPDATE' then
    if new.started_at is not distinct from old.started_at and new.ended_at is not distinct from old.ended_at
       and new.category is not distinct from old.category and new.visit_id is not distinct from old.visit_id
       and new.job_id is not distinct from old.job_id and new.notes is not distinct from old.notes then
      return null;
    end if;
  elsif not exists (select 1 from public.companies c where c.id = old.company_id) then
    -- The whole company is being deleted, and its records with it.
    return null;
  end if;

  -- What did it. The database's own writers are known by being on the way here.
  get diagnostics v_stack = pg_context;
  v_source := case
    when v_stack ~ '\mfinished_visit_clock\M' then 'finished_visit'
    when v_stack ~ '\m(clock_upkeep|stop_doubled_clocks)\M' then 'auto_stop'
    when v_stack ~ '\mone_running_clock\M' then 'next_clock'
    when v_stack ~ '\m(end_sub_clocks|sub_clock_off_visit)\M' then 'sub_off_clock'
    when tg_op = 'UPDATE' and new.geofence_out and not old.geofence_out then 'geofence'
    when tg_op = 'INSERT' and new.geofence_in then 'geofence'
    -- Its visit or job was deleted, and came off the entry with it (the foreign keys' set null).
    when tg_op = 'UPDATE' and ((old.visit_id is not null and new.visit_id is null and not exists (select 1 from public.visits v where v.id = old.visit_id))
                               or (old.job_id is not null and new.job_id is null and not exists (select 1 from public.jobs j where j.id = old.job_id))) then 'system'
    when private.assistant_client() is not null then 'assistant'
    when v_by is null or pg_trigger_depth() > 1 then 'system'
    else 'person'
  end;

  -- The clock running its course: a running clock stopped or moved, its start as it was, by a tap
  -- or by the database. Anything Timesheets sends as an edit (a reason, even an empty one) is one.
  v_edit := not (tg_op = 'UPDATE' and not v_given and old.ended_at is null and new.started_at is not distinct from old.started_at);

  insert into public.time_entry_changes (company_id, entry_id, user_id, action, changed_by, source, reason,
    old_started_at, new_started_at, old_ended_at, new_ended_at, old_category, new_category,
    old_visit_id, new_visit_id, old_job_id, new_job_id, old_notes, new_notes, edit, entry_started_at)
  values (v_row.company_id, v_row.id, v_row.user_id,
    case tg_op when 'INSERT' then 'added' when 'UPDATE' then 'changed' else 'deleted' end, v_by, v_source, v_reason,
    old.started_at, new.started_at, old.ended_at, new.ended_at, old.category, new.category,
    old.visit_id, new.visit_id, old.job_id, new.job_id, old.notes, new.notes, v_edit, v_row.started_at);

  -- Told on the bell when someone else edits their time (its times or its type) or deletes it. A
  -- tap that stops their running clock (the crew clock, the office stopping it for them) is
  -- recorded above and not announced, and neither is a change to the note, visit or job alone.
  if v_by is not null and v_by <> v_row.user_id and v_source in ('person', 'assistant')
     and (tg_op = 'DELETE'
          or (tg_op = 'UPDATE' and v_edit and (v_given
                or new.started_at is distinct from old.started_at or new.ended_at is distinct from old.ended_at
                or new.category is distinct from old.category)))
     and exists (select 1 from public.memberships m where m.company_id = v_row.company_id and m.user_id = v_row.user_id and m.active) then
    select coalesce(c.timezone, 'UTC') into v_tz from public.companies c where c.id = v_row.company_id;
    v_body := case
      when old.ended_at is null then format('It was running since %s.', to_char(old.started_at at time zone v_tz, 'FMHH12:MI AM'))
      else format('It was %s to %s.', to_char(old.started_at at time zone v_tz, 'FMHH12:MI AM'), to_char(old.ended_at at time zone v_tz, 'FMHH12:MI AM'))
    end;
    if tg_op = 'UPDATE' then
      v_body := v_body || E'\n' || case
        when new.ended_at is null then format('It''s now running since %s.', to_char(new.started_at at time zone v_tz, 'FMHH12:MI AM'))
        else format('It''s now %s to %s.', to_char(new.started_at at time zone v_tz, 'FMHH12:MI AM'), to_char(new.ended_at at time zone v_tz, 'FMHH12:MI AM'))
      end;
      if new.category is distinct from old.category then
        v_body := v_body || E'\n' || format('It''s now marked as %s.', case new.category
          when 'visit' then 'a visit' when 'assessment' then 'an assessment' when 'drive' then 'driving'
          when 'shop' then 'shop time' when 'break' then 'a break' else 'other work' end);
      end if;
    end if;
    if v_reason is not null then
      -- One line, whatever they typed: the bell reads a body line by line.
      v_body := v_body || E'\n' || format('Why: %s', regexp_replace(v_reason, '\s+', ' ', 'g'));
    end if;
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    values (v_row.company_id, v_row.user_id, 'time',
      left(format(case when tg_op = 'DELETE' then '%s deleted your time on %s' else '%s changed your time on %s' end,
        coalesce(nullif((select p.full_name from public.profiles p where p.user_id = v_by), ''), 'Someone'),
        to_char(old.started_at at time zone v_tz, 'Dy Mon FMDD')), 300),
      v_body, '/timesheets');
  end if;
  return null;
end $$;
revoke all on function private.time_entry_changed() from public;
create trigger time_entry_changed after insert or update or delete on public.time_entries
  for each row execute function private.time_entry_changed();

-- The new table's policy looks up who's asking once per query, as every other table's do.
select private.fold_member_checks('public.time_entry_changes');

notify pgrst, 'reload schema';
