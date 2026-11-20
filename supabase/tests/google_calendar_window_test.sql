-- Database tests for 20261113000200_google_calendar_window.sql: a recurring job's visits past the
-- days the Google visits calendar covers aren't queued for it (made, changed or removed), the ones
-- within them are, one that moves across the last day covered is, and a visit booked by hand goes
-- whatever its date.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tgcw;
create function tgcw.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
-- Pushes waiting for a visit (or for the whole company).
create function tgcw.pushes(p_company uuid, p_visit uuid default null) returns bigint language sql as $$
  select count(*) from public.outbox
  where company_id = p_company and topic = 'calendar.visit' and (p_visit is null or payload ->> 'visit_id' = p_visit::text)
$$;

insert into auth.users (id, email, raw_user_meta_data) values
  ('fc200000-0000-0000-0000-000000000001', 'owner@sierra.test', '{"full_name": "Sy Owner"}');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fc200000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Sierra Lawn', 'general') as co \gset
insert into public.clients (company_id, display_name) values (:'co', 'Sierra client') returning id as client \gset
insert into public.jobs (company_id, client_id, title, kind, recurrence_rule, starts_on) values (:'co', :'client', 'Weekly mowing', 'recurring', 'FREQ=WEEKLY;BYDAY=MO', current_date)
returning id as job \gset
commit;
insert into public.integrations (company_id, provider, status, settings) values (:'co', 'google_calendar', 'connected', '{"push_calendar_id": "visits@group.calendar.google.com"}');

-- ===== With no day noted yet, the calendar's six months count ====================================
insert into public.visits (company_id, job_id, title, scheduled_on, recurrence_key)
select :'co', :'job', 'Weekly mowing', current_date + d, to_char(current_date + d, 'YYYY-MM-DD') from generate_series(0, 364, 7) as d;
select tgcw.check(tgcw.pushes(:'co') = (select count(*) from public.visits where job_id = :'job' and scheduled_on <= current_date + 180),
  'a year of a recurring job''s visits queues only the six months the calendar covers');
select tgcw.check(tgcw.pushes(:'co') = 26, 'which is 26 of the 53');

-- ===== The day the nightly task has covered ======================================================
delete from public.outbox where company_id = :'co';
update public.integrations set settings = settings || jsonb_build_object('visits_through', to_char(current_date + 59, 'YYYY-MM-DD')) where company_id = :'co';
select id as near from public.visits where job_id = :'job' and scheduled_on = current_date + 56 \gset
select id as mid from public.visits where job_id = :'job' and scheduled_on = current_date + 63 \gset
select id as far from public.visits where job_id = :'job' and scheduled_on = current_date + 357 \gset

update public.visits set title = 'Mowing' where id in (:'near', :'mid', :'far');
select tgcw.check(tgcw.pushes(:'co', :'near') = 1, 'a change to a recurring visit within the days covered is queued');
select tgcw.check(tgcw.pushes(:'co', :'mid') = 0 and tgcw.pushes(:'co', :'far') = 0, 'one past them waits for the nightly task');

update public.visits set scheduled_on = current_date + 58 where id = :'mid';
select tgcw.check(tgcw.pushes(:'co', :'mid') = 1, 'one moved into the days covered is queued');
delete from public.outbox where company_id = :'co';
update public.visits set scheduled_on = current_date + 200 where id = :'mid';
select tgcw.check(tgcw.pushes(:'co', :'mid') = 1, 'and one moved out of them, so its event moves too');

delete from public.outbox where company_id = :'co';
delete from public.visits where id = :'far';
select tgcw.check(tgcw.pushes(:'co') = 0, 'removing one that never went to Google queues nothing');
delete from public.visits where id = :'near';
select tgcw.check(tgcw.pushes(:'co', :'near') = 1, 'removing one that did is queued, so it comes off');

-- ===== A visit someone books goes whatever its date ==============================================
delete from public.outbox where company_id = :'co';
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'job', 'Spring clean-up', current_date + 250) returning id as booked \gset
select tgcw.check(tgcw.pushes(:'co', :'booked') = 1, 'a visit booked by hand months away is queued when it''s booked');

-- ===== A setting that isn't a day can't stop a visit being saved ==================================
delete from public.outbox where company_id = :'co';
update public.integrations set settings = settings || '{"visits_through": "soon"}' where company_id = :'co';
insert into public.visits (company_id, job_id, title, scheduled_on, recurrence_key) values
  (:'co', :'job', 'Weekly mowing', current_date + 100, 'extra-100'), (:'co', :'job', 'Weekly mowing', current_date + 300, 'extra-300');
select tgcw.check(tgcw.pushes(:'co') = 1, 'with a setting that isn''t a day, the six months count again');
update public.integrations set settings = settings || '{"visits_through": "2999-01-01"}' where company_id = :'co';
insert into public.visits (company_id, job_id, title, scheduled_on, recurrence_key) values (:'co', :'job', 'Weekly mowing', current_date + 301, 'extra-301');
select tgcw.check(tgcw.pushes(:'co') = 1, 'and a day noted far ahead never reaches past them');

-- ===== Companies already putting visits on Google start from the 60 days they have ===============
-- (What the migration did for them, done again here for one that has no day noted.)
update public.integrations set settings = settings - 'visits_through' where company_id = :'co';
update public.integrations
set settings = settings || jsonb_build_object('visits_through', to_char(current_date + 59, 'YYYY-MM-DD'))
where provider = 'google_calendar' and settings ? 'push_calendar_id' and not settings ? 'visits_through';
select tgcw.check((select settings ->> 'visits_through' = to_char(current_date + 59, 'YYYY-MM-DD') from public.integrations where company_id = :'co'),
  'a company putting visits on Google gets the day its recurring visits reached');

delete from public.companies where id = :'co';
set client_min_messages = warning;
drop schema tgcw cascade;
reset client_min_messages;

\o
\echo 'All Google Calendar window tests passed (12 checks).'
