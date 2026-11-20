-- Database tests for 20261113000520_reminder_for_a_moved_visit.sql: the day-before reminder is due
-- once for each day a visit is on, so a visit moved to another day after its reminder went is
-- reminded for the new day, and never twice for the same one.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tvm;
grant usage on schema tvm to authenticated, service_role;
create function tvm.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
-- A time zone where it's that hour of the day right now, so the test passes at any time of day:
-- reminders go from 8 in the morning where the company is.
create function tvm.zone_at(p_hour integer) returns text language sql as $$
  with o as (select case when p_hour - extract(hour from now() at time zone 'UTC')::integer < -12 then p_hour - extract(hour from now() at time zone 'UTC')::integer + 24
                         else p_hour - extract(hour from now() at time zone 'UTC')::integer end as hours)
  select case when hours = 0 then 'UTC' when hours > 0 then 'Etc/GMT-' || hours else 'Etc/GMT+' || abs(hours) end from o
$$;
-- The days a visit has been reminded for, oldest first.
create function tvm.reminded(p_visit uuid) returns text[] language sql security definer as $$
  select coalesce(array_agg(a.data ->> 'scheduled_on' order by a.id), '{}') from public.activity a where a.subject_id = p_visit and a.verb = 'visit.reminder'
$$;
grant execute on all functions in schema tvm to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('fd520000-0000-0000-0000-000000000001', 'owner@whiskey.test', '{"full_name": "Wes Owner"}');
select tvm.zone_at(12) as noon \gset
select tvm.zone_at(4) as early \gset

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fd520000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Whiskey Windows', 'general', :'noon') as co \gset
select public.create_company('Whiskey At Dawn', 'general', :'early') as dawn \gset
select public.create_company('Whiskey Quiet', 'general', :'noon') as quiet \gset
commit;
select private.company_today(:'co') as today \gset
-- Only the reminder is looked at here.
update public.automation_rules set enabled = (template_key = 'visit_reminder') where company_id in (:'co', :'dawn');
update public.automation_rules set enabled = false where company_id = :'quiet';
insert into public.clients (company_id, display_name, email) values (:'co', 'Wyn Window', 'wyn@whiskey.test') returning id as client \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Wash the windows') returning id as job \gset
insert into public.clients (company_id, display_name) values (:'dawn', 'Dee Dawn') returning id as dawn_client \gset
insert into public.jobs (company_id, client_id, title) values (:'dawn', :'dawn_client', 'Early job') returning id as dawn_job \gset
insert into public.clients (company_id, display_name) values (:'quiet', 'Quin Quiet') returning id as quiet_client \gset
insert into public.jobs (company_id, client_id, title) values (:'quiet', :'quiet_client', 'Quiet job') returning id as quiet_job \gset

insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'job', 'Tomorrow', :'today'::date + 1) returning id as v \gset
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'job', 'In three days', :'today'::date + 3) returning id as later \gset
insert into public.visits (company_id, job_id, title, scheduled_on, status) values (:'co', :'job', 'Called off', :'today'::date + 1, 'cancelled') returning id as off \gset
insert into public.visits (company_id, kind, title, scheduled_on) values (:'co', 'task', 'Buy squeegees', :'today'::date + 1) returning id as task \gset
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'dawn', :'dawn_job', 'Before eight', private.company_today(:'dawn') + 1) returning id as dawn_visit \gset
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'quiet', :'quiet_job', 'No rule', private.company_today(:'quiet') + 1) returning id as quiet_visit \gset

\o
\echo 'The day before'
\o /dev/null
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check(tvm.reminded(:'v') = array[(:'today'::date + 1)::text], 'a visit tomorrow is due its reminder, for that day');
select tvm.check((select count(*) = 1 and bool_and(r.status = 'pending' and r.run_after <= now() + interval '1 second') from public.automation_runs r where r.subject_id = :'v'), 'and the reminder rule runs for it at once');
select tvm.check(tvm.reminded(:'later') = '{}' and tvm.reminded(:'off') = '{}' and tvm.reminded(:'task') = '{}', 'not a visit days away, a cancelled one or a task');
select tvm.check(tvm.reminded(:'dawn_visit') = '{}', 'not before 8 in the morning where the company is');
select tvm.check(tvm.reminded(:'quiet_visit') = '{}', 'and not for a company with no reminder rule on');
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check(tvm.reminded(:'v') = array[(:'today'::date + 1)::text], 'looking again an hour later reminds nobody twice');

\o
\echo 'A visit that moves'
\o /dev/null
update public.visits set starts_at = ((:'today'::date + 1) + time '14:00') at time zone :'noon', ends_at = ((:'today'::date + 1) + time '15:00') at time zone :'noon' where id = :'v';
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check(tvm.reminded(:'v') = array[(:'today'::date + 1)::text], 'a new time on the same day isn''t another reminder');

-- Reminded for a day, then moved onto tomorrow after this morning's reminders went: due at the next look.
insert into public.activity (company_id, verb, subject_type, subject_id, summary, data)
values (:'co', 'visit.reminder', 'visit', :'later', 'Reminder due: In three days', jsonb_build_object('client_id', :'client', 'scheduled_on', :'today'::date + 3));
update public.visits set scheduled_on = :'today'::date + 1 where id = :'later';
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check(tvm.reminded(:'later') = array[(:'today'::date + 3)::text, (:'today'::date + 1)::text], 'a visit moved onto tomorrow after its reminder went is reminded for the new day, the same day it moves');
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check(tvm.reminded(:'later') = array[(:'today'::date + 3)::text, (:'today'::date + 1)::text], 'once');

-- Moved away: nothing until the day before its new day. Moved back: it was already reminded for that day.
update public.visits set starts_at = null, ends_at = null, scheduled_on = :'today'::date + 6 where id = :'v';
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check(tvm.reminded(:'v') = array[(:'today'::date + 1)::text], 'a visit moved to next week waits for the day before its new day');
update public.visits set scheduled_on = :'today'::date + 1 where id = :'v';
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check(tvm.reminded(:'v') = array[(:'today'::date + 1)::text], 'moved back to the day it was reminded for, it isn''t reminded again');

-- An event that kept no day stands for whatever day the visit is on.
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'job', 'Old reminder', :'today'::date + 1) returning id as old \gset
insert into public.activity (company_id, verb, subject_type, subject_id, summary) values (:'co', 'visit.reminder', 'visit', :'old', 'Reminder due: Old reminder');
set role service_role;
select public.emit_visit_reminders();
reset role;
select tvm.check((select count(*) = 1 from public.activity where subject_id = :'old' and verb = 'visit.reminder'), 'a reminder recorded without its day still counts, so nobody is reminded twice');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fd520000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tvm.check((select count(*) = 0 from pg_proc p where p.proname = 'emit_visit_reminders' and has_function_privilege('authenticated', p.oid, 'execute')), 'only the server looks for reminders due');
commit;

delete from public.companies where id in (:'co', :'dawn', :'quiet');
set client_min_messages = warning;
drop schema tvm cascade;
reset client_min_messages;

\o
\echo 'All visit reminder tests passed (13 checks).'
