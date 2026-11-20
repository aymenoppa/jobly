-- Database tests for 20261113001810_location_notice.sql: a worker's acknowledgement of what the
-- app collects about where they are is kept with its date; only they can make it, for a company
-- they work for; the first one stands; they read their own and the office reads the team's.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tln;
grant usage on schema tln to authenticated, service_role;
create sequence tln.checks;
grant usage on sequence tln.checks to authenticated, service_role;
create function tln.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('tln.checks');
  raise notice 'ok - %', p_what;
end $$;
create function tln.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tln.fails(p_sql text) returns boolean language plpgsql as $$
begin
  execute p_sql;
  return false;
exception when others then
  return true;
end $$;
grant execute on all functions in schema tln to authenticated, service_role;

\set pat '10ca0000-0000-0000-0000-000000000001'
\set ray '10ca0000-0000-0000-0000-000000000002'
\set sam '10ca0000-0000-0000-0000-000000000003'
\set zed '10ca0000-0000-0000-0000-000000000004'

-- Everything below is rolled back at the end.
begin;
-- Pat owns Notice Lawn; Ray and Sam are crew; Zed owns another company.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@notice.test', '{"full_name": "Pat Owner"}'), (:'ray', 'ray@notice.test', '{"full_name": "Ray Crew"}'),
  (:'sam', 'sam@notice.test', '{"full_name": "Sam Crew"}'), (:'zed', 'zed@elsewhere.test', '{"full_name": "Zed Other"}');
set local role authenticated;
select tln.as_user(:'pat');
select public.create_company('Notice Lawn', 'general') as co \gset
select tln.as_user(:'zed');
select public.create_company('Elsewhere Lawn', 'general') as other \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'ray', 'field_crew'), (:'co', :'sam', 'field_crew');

\o
\echo 'A worker acknowledges the notice, and the date is kept'
\o /dev/null
set local role authenticated;
select tln.as_user(:'ray');
select tln.check((select count(*) = 0 from public.worker_notices), 'nothing is on record before they''re told');
select public.acknowledge_worker_notices(:'co', '{clock_location}') as first \gset
select tln.check((:'first'::jsonb ? 'clock_location') and not (:'first'::jsonb ? 'clock_at_property'), 'acknowledging the clock-in notice gives back what''s on record: that one');
select tln.check((select acknowledged_at = now() from public.worker_notices where company_id = :'co' and user_id = :'ray' and notice = 'clock_location'), 'with the date they acknowledged it');
-- A phone that had no signal sends when they tapped.
select public.acknowledge_worker_notices(:'co', '{clock_location,clock_at_property}', now() - interval '2 days');
select tln.check((select acknowledged_at = now() from public.worker_notices where user_id = :'ray' and notice = 'clock_location'), 'the first acknowledgement stands: a later one doesn''t move its date');
select tln.check((select acknowledged_at = now() - interval '2 days' from public.worker_notices where user_id = :'ray' and notice = 'clock_at_property'),
  'the clock-at-the-property notice is kept apart, dated when they tapped');
select tln.as_user(:'sam');
select public.acknowledge_worker_notices(:'co', '{clock_location,made_up}', now() + interval '3 days');
select tln.check((select count(*) = 1 and bool_and(notice = 'clock_location' and acknowledged_at = now()) from public.worker_notices where user_id = :'sam'),
  'a date in the future is kept as now, and a notice that doesn''t exist is ignored');
reset role;

\o
\echo 'Only the worker can say they were told'
\o /dev/null
set local role authenticated;
select tln.as_user(:'pat');
select tln.check(tln.fails(format('insert into public.worker_notices (company_id, user_id, notice) values (%L, %L, ''clock_at_property'')', :'co', :'sam')), 'the owner can''t record an acknowledgement for someone');
select tln.check(tln.fails(format('update public.worker_notices set acknowledged_at = now() - interval ''1 year'' where user_id = %L', :'ray')), 'nor change its date');
select tln.check(tln.fails(format('delete from public.worker_notices where user_id = %L', :'ray')), 'nor remove it');
select tln.as_user(:'ray');
select tln.check(tln.fails(format('delete from public.worker_notices where user_id = %L', :'ray')), 'the worker can''t take it back either');
select tln.as_user(:'zed');
select tln.check(tln.fails(format('select public.acknowledge_worker_notices(%L, ''{clock_location}'')', :'co')), 'someone outside the company can''t acknowledge anything in it');
reset role;
select set_config('request.jwt.claims', '', true);
select tln.check(tln.fails(format('select public.acknowledge_worker_notices(%L, ''{clock_location}'')', :'co')), 'nor can a request with nobody signed in');
update public.memberships set active = false where company_id = :'co' and user_id = :'sam';
set local role authenticated;
select tln.as_user(:'sam');
select tln.check(tln.fails(format('select public.acknowledge_worker_notices(%L, ''{clock_at_property}'')', :'co')), 'nor someone the company has turned off');
reset role;

\o
\echo 'Who reads it'
\o /dev/null
set local role authenticated;
select tln.as_user(:'ray');
select tln.check((select count(*) = 2 and bool_and(user_id = :'ray') from public.worker_notices), 'a worker reads their own');
select tln.as_user(:'pat');
select tln.check((select count(*) = 3 from public.worker_notices where company_id = :'co'), 'the office reads the team''s, with the dates');
select tln.as_user(:'zed');
select tln.check((select count(*) = 0 from public.worker_notices), 'another company reads none');
reset role;

rollback;

select last_value as checks from tln.checks \gset
\o
\echo 'All location notice tests passed (':checks' checks).'
