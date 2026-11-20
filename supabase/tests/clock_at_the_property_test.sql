-- Database tests for 20261113001000_clock_at_the_property.sql: a clock the phone started or stopped
-- at the property is marked so on the time entry (geofence_in, geofence_out), readable by whoever
-- reads time; a mark comes only with the clock (a running clock added, the write that stops it),
-- never later; a time changed afterwards loses its mark; the setting is off for every company; and
-- the database's own clock writes (one running clock, a finished visit's clocks) leave no mark.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tcap;
grant usage on schema tcap to authenticated, service_role;
create function tcap.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tcap.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tcap.marks(p_entry uuid) returns text language sql as $$
  select concat_ws(',', case when geofence_in then 'in' end, case when geofence_out then 'out' end) from public.time_entries where id = p_entry
$$;
grant execute on all functions in schema tcap to authenticated, service_role;

\set pat 'af100000-0000-0000-0000-000000000001'
\set ray 'af100000-0000-0000-0000-000000000002'
\set lou 'af100000-0000-0000-0000-000000000003'

-- Everything below is rolled back at the end.
begin;
-- Pat owns Arrival Lawn; Lou leads the crew Ray is on.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@arrival.test', '{"full_name": "Pat Owner"}'),
  (:'ray', 'ray@arrival.test', '{"full_name": "Ray Crew"}'),
  (:'lou', 'lou@arrival.test', '{"full_name": "Lou Lead"}');
set local role authenticated;
select tcap.as_user(:'pat');
select public.create_company('Arrival Lawn', 'general') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'ray', 'field_crew'), (:'co', :'lou', 'crew_lead');
insert into public.crews (company_id, name, lead_user_id) values (:'co', 'Mowing', :'lou') returning id as crew \gset
insert into public.crew_members (company_id, crew_id, user_id) values (:'co', :'crew', :'ray');
insert into public.visits (company_id, title, status, scheduled_on) values (:'co', '12 Oak St', 'in_progress', private.company_today(:'co')) returning id as oak \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'oak', :'ray');
select date_trunc('minute', now()) - interval '4 hours' as t0 \gset

\o
\echo 'The setting starts off'
\o /dev/null
select tcap.check((select settings -> 'clock' -> 'geofence' is null from public.companies where id = :'co'), 'a new company has nothing saved for it, which is off');

\o
\echo 'The phone marks the clocks it starts and stops at the property'
\o /dev/null
set local role authenticated;
select tcap.as_user(:'ray');
-- Arriving: travel stops and the visit's clock starts, as the clock card's tap does it.
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'drive', :'t0') returning id as drive \gset
update public.time_entries set ended_at = :'t0'::timestamptz + interval '20 minutes', geofence_out = true where id = :'drive' and ended_at is null;
insert into public.time_entries (company_id, user_id, visit_id, category, started_at, geofence_in)
values (:'co', :'ray', :'oak', 'visit', :'t0'::timestamptz + interval '20 minutes', true) returning id as onsite \gset
select tcap.check(tcap.marks(:'drive') = 'out' and tcap.marks(:'onsite') = 'in', 'the stop and the start made at the property are marked');
select tcap.check((select geofence_in and not geofence_out from public.time_entries where id = :'onsite'), 'and field crew can read the marks on their own time');
-- Leaving.
update public.time_entries set ended_at = :'t0'::timestamptz + interval '2 hours', geofence_out = true where id = :'onsite' and ended_at is null;
select tcap.check(tcap.marks(:'onsite') = 'in,out', 'leaving marks the stop too');

\o
\echo 'A mark comes only with the clock'
\o /dev/null
-- Added already stopped (Timesheets' Add time): not a start the phone made.
insert into public.time_entries (company_id, user_id, category, started_at, ended_at, geofence_in, geofence_out)
values (:'co', :'ray', 'shop', :'t0'::timestamptz - interval '3 hours', :'t0'::timestamptz - interval '2 hours', true, true) returning id as added \gset
select tcap.check(tcap.marks(:'added') = '', 'time added already stopped has no mark, whatever is sent');
-- A tap's clock, marked later.
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'shop', :'t0'::timestamptz + interval '3 hours') returning id as tap \gset
update public.time_entries set geofence_in = true where id = :'tap';
select tcap.check(tcap.marks(:'tap') = '', 'a running clock can''t be marked as started at the property afterwards');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '3 hours 30 minutes' where id = :'tap';
update public.time_entries set geofence_out = true where id = :'tap';
select tcap.check(tcap.marks(:'tap') = '', 'nor a stopped one as stopped there');
-- Jobly stopping a clock that arrives late (one running clock) isn't the phone's stop.
insert into public.time_entries (company_id, user_id, category, started_at, geofence_in) values (:'co', :'ray', 'visit', :'t0'::timestamptz + interval '4 hours', true) returning id as later \gset
insert into public.time_entries (company_id, user_id, category, started_at, geofence_in) values (:'co', :'ray', 'drive', :'t0'::timestamptz + interval '3 hours 50 minutes', true) returning id as late \gset
select tcap.check(tcap.marks(:'late') = 'in' and (select ended_at from public.time_entries where id = :'late') = :'t0'::timestamptz + interval '4 hours',
  'a start the phone sent late keeps its mark and is still ended where the newer clock begins');
-- A tap starting a clock stops the one running (one_running_clock): that stop is no mark.
insert into public.time_entries (company_id, user_id, category, started_at) values (:'co', :'ray', 'break', :'t0'::timestamptz + interval '4 hours 30 minutes') returning id as lunch \gset
select tcap.check(tcap.marks(:'later') = 'in' and (select ended_at is not null from public.time_entries where id = :'later'), 'the clock a tap replaces is stopped with no mark for the stop');

\o
\echo 'A time changed afterwards is the person''s own'
\o /dev/null
reset role;
set local role authenticated;
select tcap.as_user(:'pat');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '2 hours 15 minutes' where id = :'onsite';
select tcap.check(tcap.marks(:'onsite') = 'in', 'the office fixing the end time takes the stop''s mark off');
update public.time_entries set started_at = :'t0'::timestamptz + interval '25 minutes' where id = :'onsite';
select tcap.check(tcap.marks(:'onsite') = '', 'and fixing the start takes the start''s off');
update public.time_entries set notes = 'Mowed and edged' where id = :'drive';
select tcap.check(tcap.marks(:'drive') = 'out', 'a note changes nothing');
select tcap.as_user(:'lou');
select tcap.check((select count(*) = 1 from public.time_entries where id = :'drive' and geofence_out), 'a crew lead reads the marks on their crew''s time');
reset role;

\o
\echo 'Finishing a visit leaves no mark'
\o /dev/null
update public.companies set settings = jsonb_set(settings, '{clock,mode}', '"day"') where id = :'co';
insert into public.visits (company_id, title, status, scheduled_on) values (:'co', '8 Elm Ave', 'in_progress', private.company_today(:'co')) returning id as elm \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'elm', :'lou');
set local role authenticated;
select tcap.as_user(:'lou');
insert into public.time_entries (company_id, user_id, visit_id, category, started_at, geofence_in) values (:'co', :'lou', :'elm', 'visit', now() - interval '30 minutes', true) returning id as elm1 \gset
select tcap.as_user(:'pat');
update public.visits set status = 'completed', completed_at = now() - interval '5 minutes' where id = :'elm';
reset role;
select tcap.check(tcap.marks(:'elm1') = 'in', 'the visit''s clock ends with no mark for the stop');
select tcap.check((select count(*) = 1 from public.time_entries where user_id = :'lou' and ended_at is null and category = 'drive' and not geofence_in and not geofence_out),
  'and the travel it starts on the whole-day clock has none');

rollback;

\o
\echo 'All clock at the property tests passed.'
