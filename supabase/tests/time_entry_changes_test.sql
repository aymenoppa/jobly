-- Database tests for 20261113001800_time_entry_changes.sql: every change to a worker's time is on
-- record (time added by someone else, every update of the times, type, visit, job or note, every
-- delete), with who, when, the old and new values, why if given, and what did it; the worker reads
-- the changes to their own time and is told on the bell when someone else edits or deletes it; the
-- office and their crew lead read them too; and nobody can add, edit or delete a record.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema ttc;
grant usage on schema ttc to authenticated, service_role;
create sequence ttc.checks;
grant usage on sequence ttc.checks to authenticated, service_role;
create function ttc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('ttc.checks');
  raise notice 'ok - %', p_what;
end $$;
create function ttc.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- The record of an entry, oldest first, as "action/source/by" lines (by: the email's first part, or "nobody").
create function ttc.record(p_entry uuid) returns text language sql security definer as $$
  select coalesce(string_agg(c.action || '/' || c.source || '/' || coalesce(split_part(u.email, '@', 1), 'nobody'), ', ' order by c.changed_at, c.id), '')
  from public.time_entry_changes c left join auth.users u on u.id = c.changed_by where c.entry_id = p_entry
$$;
create function ttc.last(p_entry uuid) returns public.time_entry_changes language sql security definer as $$
  select c from public.time_entry_changes c where c.entry_id = p_entry order by c.changed_at desc, c.id desc limit 1
$$;
-- What someone was told about their time, newest first, as "title | body".
create function ttc.told(p_user uuid) returns text language sql security definer as $$
  select coalesce(string_agg(n.title || ' | ' || replace(coalesce(n.body, ''), E'\n', ' / '), E'\n' order by n.created_at desc, n.id), '')
  from public.notifications n where n.user_id = p_user and n.kind = 'time' and n.title like '% your time on %'
$$;
create function ttc.fails(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end $$;
grant execute on all functions in schema ttc to authenticated, service_role;

\set pat 'c4a90000-0000-0000-0000-000000000001'
\set ray 'c4a90000-0000-0000-0000-000000000002'
\set lou 'c4a90000-0000-0000-0000-000000000003'
\set sam 'c4a90000-0000-0000-0000-000000000004'
\set zed 'c4a90000-0000-0000-0000-000000000005'

-- Everything below is rolled back at the end.
begin;
-- Pat owns Record Lawn (Eastern time); Lou leads the crew Ray is on; Sam is on no crew; Zed owns another company.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@record.test', '{"full_name": "Pat Owner"}'),
  (:'ray', 'ray@record.test', '{"full_name": "Ray Crew"}'),
  (:'lou', 'lou@record.test', '{"full_name": "Lou Lead"}'),
  (:'sam', 'sam@record.test', '{"full_name": "Sam Crew"}'),
  (:'zed', 'zed@other.test', '{"full_name": "Zed Other"}');
set local role authenticated;
select ttc.as_user(:'pat');
select public.create_company('Record Lawn', 'general') as co \gset
select ttc.as_user(:'zed');
select public.create_company('Other Lawn', 'general') as other \gset
reset role;
-- The visits-only clock, so finishing a visit just stops its clocks.
update public.companies set timezone = 'America/New_York', settings = jsonb_set(settings, '{clock,mode}', '"visits"') where id = :'co';
insert into public.memberships (company_id, user_id, role) values (:'co', :'ray', 'field_crew'), (:'co', :'lou', 'crew_lead'), (:'co', :'sam', 'field_crew');
insert into public.crews (company_id, name, lead_user_id) values (:'co', 'Mowing', :'lou') returning id as crew \gset
insert into public.crew_members (company_id, crew_id, user_id) values (:'co', :'crew', :'ray');
-- Monday Nov 9 2026, 8:00 in the morning in New York.
\set t0 '2026-11-09 13:00:00+00'

\o
\echo 'A person''s own clock is its own record; stopping it is a change'
\o /dev/null
set local role authenticated;
select ttc.as_user(:'ray');
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'shop', :'t0') returning id as shop \gset
select ttc.check(ttc.record(:'shop') = '', 'clocking in records nothing: the entry is the record');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '4 hours' where id = :'shop';
select ttc.check(ttc.record(:'shop') = 'changed/person/ray', 'stopping their own clock is recorded as their own tap');
select ttc.check((select (c).old_ended_at is null and (c).new_ended_at = :'t0'::timestamptz + interval '4 hours' and (c).old_started_at = :'t0' and (c).new_started_at = :'t0'
  and (c).old_category = 'shop' and (c).new_category = 'shop' and (c).reason is null and (c).user_id = :'ray' and (c).company_id = :'co' from ttc.last(:'shop') c),
  'with the old and new start, end and type');
insert into public.time_entries (company_id, user_id, category, started_at, ended_at) values (:'co', :'ray', 'other', :'t0'::timestamptz - interval '2 hours', :'t0'::timestamptz - interval '1 hour') returning id as own \gset
select ttc.check(ttc.record(:'own') = '', 'time they add for themselves records nothing either');
select ttc.check(ttc.told(:'ray') = '', 'and nobody is told about their own taps');
reset role;

\o
\echo 'The office changes someone''s time: on record, with why, and the worker is told'
\o /dev/null
set local role authenticated;
select ttc.as_user(:'pat');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '3 hours 30 minutes', change_reason = '  Left at 11:30 for the dentist ' where id = :'shop';
select ttc.check(ttc.record(:'shop') = 'changed/person/ray, changed/person/pat', 'the office''s edit is a second record, in the office''s name');
select ttc.check((select (c).old_ended_at = :'t0'::timestamptz + interval '4 hours' and (c).new_ended_at = :'t0'::timestamptz + interval '3 hours 30 minutes'
  and (c).reason = 'Left at 11:30 for the dentist' and (c).changed_at is not null from ttc.last(:'shop') c), 'it keeps the end as it was, as it is now, and why');
reset role;
select ttc.check((select change_reason is null from public.time_entries where id = :'shop'), 'the reason is kept with the record, not on the entry');
select ttc.check(ttc.told(:'ray') = 'Pat Owner changed your time on Mon Nov 9 | It was 8:00 AM to 12:00 PM. / It''s now 8:00 AM to 11:30 AM. / Why: Left at 11:30 for the dentist',
  'the worker is told on the bell: who, which day, what it was, what it is now and why');
select ttc.check((select link = '/timesheets' from public.notifications where user_id = :'ray' and kind = 'time'), 'and the notification opens Timesheets');
delete from public.notifications where user_id = :'ray';

set local role authenticated;
select ttc.as_user(:'pat');
-- A reason given for one write isn't carried to the next.
update public.time_entries set category = 'break', notes = 'Lunch' where id = :'shop';
select ttc.check((select (c).reason is null and (c).old_category = 'shop' and (c).new_category = 'break' and (c).old_notes is null and (c).new_notes = 'Lunch' from ttc.last(:'shop') c),
  'a change of type and note is recorded, with no reason left over from the edit before');
reset role;
select ttc.check(ttc.told(:'ray') = 'Pat Owner changed your time on Mon Nov 9 | It was 8:00 AM to 11:30 AM. / It''s now 8:00 AM to 11:30 AM. / It''s now marked as a break.',
  'turning their time into a break is told too');
delete from public.notifications where user_id = :'ray';
set local role authenticated;
select ttc.as_user(:'pat');
update public.time_entries set notes = 'Lunch at the shop' where id = :'shop';
select ttc.check(ttc.record(:'shop') = 'changed/person/ray, changed/person/pat, changed/person/pat, changed/person/pat', 'a note alone is recorded');
select ttc.check(ttc.told(:'ray') = '', 'but not announced: it changes nothing they''re paid for');
select ttc.check((select not (array_agg(c.edit order by c.changed_at))[1] and (array_agg(c.edit order by c.changed_at))[2:4] = '{t,t,t}' and bool_and(c.entry_started_at = :'t0')
  from public.time_entry_changes c where c.entry_id = :'shop'), 'their own stop is the clock running its course; what the office did after are edits, each filed under the entry''s start');
-- Approving isn't a change to the time (the entry keeps who approved it).
update public.time_entries set approved_at = now(), approved_by = :'pat' where id = :'shop';
update public.time_entries set approved_at = null, approved_by = null where id = :'shop';
select ttc.check((select count(*) = 4 from public.time_entry_changes where entry_id = :'shop'), 'approving and taking approval back record nothing here');
-- Time added for someone.
insert into public.time_entries (company_id, user_id, category, started_at, ended_at, notes, change_reason)
values (:'co', :'ray', 'other', :'t0'::timestamptz + interval '5 hours', :'t0'::timestamptz + interval '6 hours', 'Forgot to clock in', 'He called it in') returning id as added \gset
select ttc.check(ttc.record(:'added') = 'added/person/pat', 'time the office adds for someone is recorded as added');
select ttc.check((select (c).old_started_at is null and (c).new_started_at = :'t0'::timestamptz + interval '5 hours' and (c).new_ended_at = :'t0'::timestamptz + interval '6 hours'
  and (c).new_category = 'other' and (c).new_notes = 'Forgot to clock in' and (c).reason = 'He called it in' from ttc.last(:'added') c), 'with what was added and why');
reset role;

\o
\echo 'Deleting someone''s time: the record stays, and the worker is told'
\o /dev/null
set local role authenticated;
select ttc.as_user(:'pat');
select ttc.check(public.delete_time_entry(:'added', 'Added twice'), 'the office deletes an entry and says why');
select ttc.check((select count(*) = 0 from public.time_entries where id = :'added'), 'the entry is gone');
select ttc.check(ttc.record(:'added') = 'added/person/pat, deleted/person/pat', 'its record is not');
select ttc.check((select (c).old_started_at = :'t0'::timestamptz + interval '5 hours' and (c).old_ended_at = :'t0'::timestamptz + interval '6 hours' and (c).new_started_at is null
  and (c).new_ended_at is null and (c).old_category = 'other' and (c).old_notes = 'Forgot to clock in' and (c).reason = 'Added twice' from ttc.last(:'added') c),
  'it keeps what the deleted entry said, and why it was deleted');
select ttc.check(not public.delete_time_entry(:'added', 'Again'), 'deleting it again finds nothing');
select ttc.check(not public.delete_time_entry(gen_random_uuid()), 'as does an entry that never was');
-- A plain delete (an app from before this, or anything else): recorded all the same.
delete from public.time_entries where id = :'own';
select ttc.check(ttc.record(:'own') = 'deleted/person/pat' and (select (c).reason is null from ttc.last(:'own') c), 'a plain delete is recorded too, with no reason');
reset role;
select ttc.check(ttc.told(:'ray') = E'Pat Owner deleted your time on Mon Nov 9 | It was 6:00 AM to 7:00 AM.\nPat Owner deleted your time on Mon Nov 9 | It was 1:00 PM to 2:00 PM. / Why: Added twice'
  or ttc.told(:'ray') = E'Pat Owner deleted your time on Mon Nov 9 | It was 1:00 PM to 2:00 PM. / Why: Added twice\nPat Owner deleted your time on Mon Nov 9 | It was 6:00 AM to 7:00 AM.',
  'the worker is told about each, with why where it was said');
delete from public.notifications where user_id = :'ray';
-- Someone can't delete time that isn't theirs to delete through it.
set local role authenticated;
select ttc.as_user(:'sam');
select ttc.check(not public.delete_time_entry(:'shop', 'Not mine'), 'a crew member can''t delete someone else''s time through it');
select ttc.as_user(:'zed');
select ttc.check(not public.delete_time_entry(:'shop', 'Not my company'), 'nor can another company');
reset role;
select ttc.check((select count(*) = 1 from public.time_entries where id = :'shop'), 'the entry is still there');

\o
\echo 'A crew lead''s taps are recorded and not announced; their edits are'
\o /dev/null
set local role authenticated;
select ttc.as_user(:'ray');
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'shop', :'t0'::timestamptz + interval '1 day') returning id as day2 \gset
select ttc.as_user(:'lou');
-- The crew clock: Lou stops Ray's clock.
update public.time_entries set ended_at = :'t0'::timestamptz + interval '1 day 8 hours' where id = :'day2' and ended_at is null;
select ttc.check(ttc.record(:'day2') = 'changed/person/lou' and (select not (c).edit from ttc.last(:'day2') c), 'a crew lead stopping their crew''s clock is recorded in the lead''s name, as a tap');
select ttc.check(ttc.told(:'ray') = '', 'and isn''t announced: the crew clock doesn''t ring every phone at the end of the day');
-- The same stop moved from Timesheets, which says it's an edit (a reason, even an empty one).
update public.time_entries set started_at = :'t0'::timestamptz + interval '1 day 1 hour', change_reason = '' where id = :'day2';
select ttc.check((select (c).reason is null and (c).old_started_at = :'t0'::timestamptz + interval '1 day' and (c).new_started_at = :'t0'::timestamptz + interval '1 day 1 hour' from ttc.last(:'day2') c),
  'an edit with no reason is recorded with none');
select ttc.check((select (c).edit and (c).entry_started_at = :'t0'::timestamptz + interval '1 day 1 hour' from ttc.last(:'day2') c), 'as an edit, filed where the entry starts now');
reset role;
select ttc.check(ttc.told(:'ray') = 'Lou Lead changed your time on Tue Nov 10 | It was 8:00 AM to 4:00 PM. / It''s now 9:00 AM to 4:00 PM.', 'and the worker is told their start was moved');
delete from public.notifications where user_id = :'ray';
-- A running clock stopped from Timesheets (an edit): told, though it's only a stop.
set local role authenticated;
select ttc.as_user(:'ray');
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'shop', :'t0'::timestamptz + interval '2 days') returning id as day3 \gset
select ttc.as_user(:'pat');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '2 days 2 hours', change_reason = '' where id = :'day3';
reset role;
select ttc.check(ttc.told(:'ray') = 'Pat Owner changed your time on Wed Nov 11 | It was running since 8:00 AM. / It''s now 8:00 AM to 10:00 AM.', 'a running clock ended from Timesheets is told');
delete from public.notifications where user_id = :'ray';

\o
\echo 'What Jobly does by itself is recorded with what did it'
\o /dev/null
-- Starting another clock ends the one running.
set local role authenticated;
select ttc.as_user(:'ray');
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'drive', now() - interval '3 hours') returning id as drive \gset
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'shop', now() - interval '2 hours') returning id as shop2 \gset
select ttc.check(ttc.record(:'drive') = 'changed/next_clock/ray', 'a clock ended by the next one starting says so');
-- The phone, at the property.
update public.time_entries set ended_at = now() - interval '90 minutes', geofence_out = true where id = :'shop2' and ended_at is null;
select ttc.check(ttc.record(:'shop2') = 'changed/geofence/ray', 'a clock the phone moved at the property says it was the phone');
reset role;
-- Completing a visit ends the clocks still on it.
insert into public.visits (company_id, title, status, scheduled_on) values (:'co', '12 Oak St', 'in_progress', private.company_today(:'co')) returning id as oak \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'oak', :'ray');
set local role authenticated;
select ttc.as_user(:'ray');
insert into public.time_entries (company_id, user_id, visit_id, category, started_at) values (:'co', :'ray', :'oak', 'visit', now() - interval '1 hour') returning id as onsite \gset
select ttc.as_user(:'pat');
update public.visits set status = 'completed', completed_at = now() - interval '5 minutes' where id = :'oak';
reset role;
select ttc.check((select ended_at is not null from public.time_entries where id = :'onsite'), 'completing the visit ended the clock on it');
select ttc.check(ttc.record(:'onsite') = 'changed/finished_visit/pat', 'and the record says the visit being finished did it, and who finished it');
-- A deleted visit comes off the entry.
delete from public.visits where id = :'oak';
select ttc.check(ttc.record(:'onsite') like 'changed/finished_visit/pat, changed/system/%' and (select (c).old_visit_id = :'oak' and (c).new_visit_id is null from ttc.last(:'onsite') c),
  'a visit deleted from under an entry is recorded as Jobly''s doing');
select ttc.check(ttc.told(:'ray') = '', 'none of that is announced as someone changing their time');
-- The hourly upkeep stops a clock left running: nobody is signed in.
set local role authenticated;
select ttc.as_user(:'sam');
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'sam', 'shop', now() - interval '30 hours') returning id as left_on \gset
reset role;
select set_config('request.jwt.claims', '', true);
select public.clock_upkeep();
select ttc.check((select ended_at is not null and auto_stopped_at is not null from public.time_entries where id = :'left_on'), 'the upkeep stopped a clock left running');
select ttc.check(ttc.record(:'left_on') = 'changed/auto_stop/nobody', 'recorded as stopped by the upkeep, with nobody signed in');
select ttc.check((select count(*) = 4 and count(*) filter (where edit) = 0 from public.time_entry_changes where company_id = :'co' and source in ('next_clock', 'geofence', 'finished_visit', 'auto_stop')),
  'the clocks Jobly stopped by itself are the clock running its course, not edits');
select ttc.check((select (c).edit and (c).entry_started_at = :'t0'::timestamptz + interval '5 hours' from ttc.last(:'added') c) and (select bool_and(c.edit) from public.time_entry_changes c where c.entry_id = :'own'),
  'time added for someone and every delete do');
-- An AI assistant connected to the office's account.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'pat', 'role', 'authenticated', 'client_id', 'assistant-1')::text, true);
-- Later, not earlier: stopped at 18:00, it may have run for less than an hour.
update public.time_entries set ended_at = ended_at + interval '1 hour', auto_stopped_at = null where id = :'left_on';
reset role;
select ttc.check(ttc.record(:'left_on') = 'changed/auto_stop/nobody, changed/assistant/pat', 'an assistant''s change is recorded as the assistant''s, under whose account it is');
select ttc.check(ttc.told(:'sam') like 'Pat Owner changed your time on %', 'and the worker is told');

\o
\echo 'Who reads the record'
\o /dev/null
set local role authenticated;
select ttc.as_user(:'ray');
select ttc.check((select count(*) > 0 and count(*) filter (where user_id <> :'ray') = 0 from public.time_entry_changes), 'a worker reads the changes to their own time, and nobody else''s');
select ttc.check((select count(*) = 2 from public.time_entry_changes where entry_id = :'added'), 'including the record of their time that was deleted');
select ttc.as_user(:'sam');
select ttc.check((select count(*) = 2 and count(*) filter (where user_id <> :'sam') = 0 from public.time_entry_changes), 'another crew member reads only their own');
select ttc.as_user(:'lou');
select ttc.check((select count(*) filter (where user_id = :'ray') > 0 and count(*) filter (where user_id = :'sam') = 0 from public.time_entry_changes), 'a crew lead reads their crew''s, not the rest of the team''s');
select ttc.as_user(:'pat');
select ttc.check((select count(distinct user_id) = 2 from public.time_entry_changes), 'the office reads everyone''s');
select ttc.as_user(:'zed');
select ttc.check((select count(*) = 0 from public.time_entry_changes), 'another company reads none of it');
reset role;

\o
\echo 'Nobody adds to it, edits it or deletes from it'
\o /dev/null
set local role authenticated;
select ttc.as_user(:'pat');
select ttc.check(ttc.fails(format('insert into public.time_entry_changes (company_id, entry_id, user_id, action, source, edit, entry_started_at) values (%L, %L, %L, ''changed'', ''person'', true, now())', :'co', :'shop', :'ray')),
  'an owner can''t write a record by hand');
select ttc.check(ttc.fails(format('update public.time_entry_changes set reason = ''Tidied'' where entry_id = %L', :'shop')), 'nor edit one');
select ttc.check(ttc.fails(format('delete from public.time_entry_changes where entry_id = %L', :'shop')), 'nor delete one');
select ttc.as_user(:'ray');
select ttc.check(ttc.fails(format('delete from public.time_entry_changes where entry_id = %L', :'shop')), 'nor can the worker');
reset role;
-- The server can't edit or delete one either.
select ttc.check(ttc.fails(format('update public.time_entry_changes set reason = ''Tidied'' where entry_id = %L', :'shop')), 'the server can''t edit a record');
select ttc.check(ttc.fails(format('delete from public.time_entry_changes where entry_id = %L', :'shop')), 'or delete one');
select ttc.check((select count(*) = 4 from public.time_entry_changes where entry_id = :'shop'), 'every record is still there');
-- They go only with their company.
select count(*) as before from public.time_entry_changes where company_id = :'co' \gset
delete from public.companies where id = :'co';
select ttc.check(:before > 10 and (select count(*) = 0 from public.time_entry_changes where company_id = :'co'), 'deleting the company takes its records with it, and nothing stops that');

rollback;

select last_value as checks from ttc.checks \gset
\o
\echo 'All time entry change tests passed (':checks' checks).'
