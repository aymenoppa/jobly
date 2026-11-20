-- Database tests for 20261113000220_recurring_schedule_one_notice.sql: when the server changes a
-- recurring job's waiting visits (a new time or crew with "Change the upcoming visits too", a new
-- repeat, a pause), each person on them hears once, in one line, however many visits it is; a new
-- title alone tells nobody; and only the server can take a job's waiting visits off.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema trsn;
grant usage on schema trsn to authenticated, service_role;
create function trsn.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function trsn.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
-- The lines of someone's schedule notifications that haven't been read, oldest first, and how many notifications that is.
create function trsn.lines(p_user uuid) returns text[] language sql security definer as $$
  select coalesce(array_agg(l order by n.created_at, o), '{}')
  from public.notifications n cross join lateral unnest(string_to_array(n.body, E'\n')) with ordinality as x(l, o)
  where n.user_id = p_user and n.kind = 'schedule' and n.read_at is null
$$;
create function trsn.count(p_user uuid) returns bigint language sql security definer as $$
  select count(*) from public.notifications n where n.user_id = p_user and n.kind = 'schedule' and n.read_at is null
$$;
create function trsn.read_all() returns void language sql security definer as $$
  update public.notifications set read_at = now() where read_at is null and user_id::text like 'fd220000-%'
$$;
grant execute on all functions in schema trsn to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('fd220000-0000-0000-0000-000000000001', 'owner@uniform.test', '{"full_name": "Una Owner"}'),
  ('fd220000-0000-0000-0000-00000000000a', 'ann@uniform.test', '{"full_name": "Ann Mower"}'),
  ('fd220000-0000-0000-0000-00000000000b', 'bob@uniform.test', '{"full_name": "Bob Mower"}'),
  ('fd220000-0000-0000-0000-00000000000c', 'cy@uniform.test', '{"full_name": "Cy Trees"}'),
  ('fd220000-0000-0000-0000-00000000000d', 'dee@uniform.test', '{"full_name": "Dee Floater"}');
\set ann '''fd220000-0000-0000-0000-00000000000a'''
\set bob '''fd220000-0000-0000-0000-00000000000b'''
\set cy '''fd220000-0000-0000-0000-00000000000c'''
\set dee '''fd220000-0000-0000-0000-00000000000d'''

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fd220000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Uniform Lawn', 'general', 'America/Chicago') as co \gset
insert into public.memberships (company_id, user_id, role) values
  (:'co', :ann, 'field_crew'), (:'co', :bob, 'field_crew'), (:'co', :cy, 'field_crew'), (:'co', :dee, 'field_crew');
insert into public.crews (company_id, name) values (:'co', 'Mowing') returning id as mowing \gset
insert into public.crews (company_id, name) values (:'co', 'Trees') returning id as trees \gset
insert into public.crew_members (company_id, crew_id, user_id) values (:'co', :'mowing', :ann), (:'co', :'mowing', :bob), (:'co', :'trees', :cy);
insert into public.clients (company_id, display_name) values (:'co', 'Mowed client') returning id as client \gset
insert into public.jobs (company_id, client_id, title, kind, recurrence_rule, starts_on, default_crew_id, visit_start_time, visit_duration_min)
values (:'co', :'client', 'Weekly mowing', 'recurring', 'FREQ=WEEKLY;BYDAY=MO', current_date, :'mowing', '09:00', 60) returning id as job, number as job_number \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Stump') returning id as job2 \gset
commit;
-- A year of the job's weekly visits, as the nightly task makes them: its crew and nobody listed.
insert into public.visits (company_id, job_id, title, crew_id, scheduled_on, starts_at, ends_at, recurrence_key)
select :'co', :'job', 'Weekly mowing', :'mowing', d::date, private.zoned_time(d::date, '09:00', 'America/Chicago'), private.zoned_time(d::date, '10:00', 'America/Chicago'), to_char(d, 'YYYY-MM-DD')
from generate_series(private.company_today(:'co') + 7, private.company_today(:'co') + 364, interval '7 days') d;
-- Dee is listed on one of them, and there's a one-off visit on another job.
select id as v_dee from public.visits where job_id = :'job' order by scheduled_on offset 40 limit 1 \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'v_dee', :dee);
insert into public.visits (company_id, job_id, title, crew_id, scheduled_on) values (:'co', :'job2', 'Grind the stump', :'trees', private.company_today(:'co') + 3) returning id as v_other \gset
select trsn.read_all();

\o
\echo 'A recurring schedule changing, told once'
\o /dev/null

-- ===== "Change the upcoming visits too" ===========================================================
update public.jobs set visit_start_time = '13:00' where id = :'job';
set role service_role;
select trsn.check(public.refresh_upcoming_visits(:'job') = 52, 'the job''s new time goes onto all 52 waiting visits');
reset role;
select trsn.check(trsn.count(:ann) = 1 and trsn.lines(:ann) = array[format('The upcoming visits for job #%s (Weekly mowing) changed', :'job_number')] and trsn.lines(:bob) = trsn.lines(:ann),
  'and each person on its crew hears once, in one line');
select trsn.check(trsn.lines(:dee) = trsn.lines(:ann), 'so does someone listed on one of them');
select trsn.check(trsn.count(:cy) = 0, 'and nobody else');
select trsn.check((select link = '/field' from public.notifications where user_id = :ann and read_at is null), 'it opens their day, there being no one visit to open');

-- Asked again with nothing changed, or with only a new title: nobody's day changed.
select trsn.read_all();
set role service_role;
select trsn.check(public.refresh_upcoming_visits(:'job') = 52, 'asked again with nothing changed');
reset role;
update public.jobs set title = 'Mowing' where id = :'job';
set role service_role;
select trsn.check(public.refresh_upcoming_visits(:'job') = 52, 'and with only a new title, which goes onto them');
reset role;
select trsn.check(trsn.count(:ann) = 0 and trsn.count(:dee) = 0 and (select bool_and(title = 'Mowing') from public.visits where job_id = :'job' and recurrence_key is not null), 'nobody is told');

-- A new crew for the job: the old crew and the new one hear, once each. The visit with Dee listed
-- has none of the old crew listed, so its list stays.
update public.jobs set default_crew_id = :'trees' where id = :'job';
set role service_role;
select public.refresh_upcoming_visits(:'job');
reset role;
select trsn.check(trsn.count(:ann) = 1 and cardinality(trsn.lines(:ann)) = 1 and trsn.lines(:bob) = trsn.lines(:ann), 'a new crew tells the old crew once');
select trsn.check(trsn.count(:cy) = 1 and trsn.lines(:cy) = array[format('The upcoming visits for job #%s (Mowing) changed', :'job_number')], 'and the new crew once');
select trsn.check((select array_agg(user_id) from public.visit_assignees where visit_id = :'v_dee') = array[:dee]::uuid[], 'people picked by hand stay on their visit');

-- Within the ten minutes a notification gathers changes, the same line isn't said twice.
update public.jobs set visit_start_time = '08:00' where id = :'job';
set role service_role;
select public.refresh_upcoming_visits(:'job');
reset role;
select trsn.check(trsn.count(:cy) = 1 and cardinality(trsn.lines(:cy)) = 1, 'a second change moments later joins the first, as the same one line');

-- ===== Taking a job's waiting visits off (a new repeat, or a pause) ==============================
select trsn.read_all();
select array_agg(id) as some from (select id from public.visits where job_id = :'job' and recurrence_key is not null order by scheduled_on limit 30) x \gset
set role service_role;
select trsn.check(public.remove_recurring_visits(:'job', :'some') = 30, 'the server takes thirty of the job''s waiting visits off');
reset role;
select trsn.check(trsn.count(:cy) = 1 and trsn.lines(:cy) = array[format('The upcoming visits for job #%s (Mowing) changed', :'job_number')], 'and the people who were on them hear once');
select trsn.check(trsn.count(:ann) = 0 and trsn.count(:dee) = 0, 'not people who weren''t on those');
select trsn.check((select count(*) from public.visits where job_id = :'job' and recurrence_key is not null) = 22, 'the rest stay');
select trsn.check((select count(*) from public.recurrence_skips where job_id = :'job') = 0, 'their dates aren''t remembered as deleted by someone, so a new repeat can have them again');

select trsn.read_all();
set role service_role;
select trsn.check(public.remove_recurring_visits(:'job', array[:'v_other']::uuid[]) = 0 and public.remove_recurring_visits(:'job2', array[:'v_other']::uuid[]) = 0,
  'a visit of another job, or one nobody made from a repeat, isn''t taken off');
select trsn.check(public.remove_recurring_visits(:'job', '{}') = 0 and public.remove_recurring_visits(gen_random_uuid(), array[:'v_dee']::uuid[]) = 0, 'no visits, or no such job: nothing');
reset role;
select trsn.check(exists (select 1 from public.visits where id = :'v_other') and exists (select 1 from public.visits where id = :'v_dee') and trsn.count(:cy) = 0, 'and nobody is told');
-- One that's started stays.
update public.visits set status = 'in_progress' where id = :'v_dee';
set role service_role;
select trsn.check(public.remove_recurring_visits(:'job', array[:'v_dee']::uuid[]) = 0, 'a visit that has started isn''t taken off');
reset role;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "fd220000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select trsn.expect_error(format('select public.remove_recurring_visits(%L, %L)', :'job', '{}'), 'nobody signed in can ask for that');
select trsn.expect_error(format('select public.refresh_upcoming_visits(%L)', :'job'), 'or for the other');
rollback;

-- ===== Changes people make themselves are still told visit by visit ===============================
select trsn.read_all();
select id as v_next from public.visits where job_id = :'job' and recurrence_key is not null and status = 'scheduled' order by scheduled_on limit 1 \gset
update public.visits set scheduled_on = scheduled_on + 1, starts_at = starts_at + interval '1 day', ends_at = ends_at + interval '1 day' where id = :'v_next';
select trsn.check((trsn.lines(:cy))[1] like 'Mowing moved to % (was %)' and cardinality(trsn.lines(:cy)) = 1, 'one visit moved by hand tells the people on it about that visit');

delete from public.companies where id = :'co';
set client_min_messages = warning;
drop schema trsn cascade;
reset client_min_messages;

\o
\echo 'All recurring schedule notice tests passed (24 checks).'
