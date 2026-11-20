-- Database tests for clock taps sent late (apps/web/src/features/field/fieldActions.ts setClock):
-- the statements a phone sends for a Start, Switch or Stop made with no signal, run here as the
-- person, against the rules that keep one clock running each
-- (20261112000410_one_running_clock.sql). A clock is added under an id the phone made, so the same
-- tap sent twice adds it once and changes nothing else; a Stop only ends clocks that began before
-- it was tapped; and a start that arrives after a newer clock is saved up to where that one began.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tct;
grant usage on schema tct to authenticated, service_role;
create function tct.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tct.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tct.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tct.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
-- Someone's time as "category from-to" in the order it began, in minutes after t0 ("-" while running).
create function tct.day_of(p_user uuid, p_t0 timestamptz) returns text language sql as $$
  select string_agg(category || ' ' || (extract(epoch from started_at - p_t0) / 60)::int || '-' || coalesce((extract(epoch from ended_at - p_t0) / 60)::int::text, ''), ', ' order by started_at, created_at)
  from public.time_entries where user_id = p_user
$$;
grant execute on all functions in schema tct to authenticated, service_role;

\set pat 'c7a90000-0000-0000-0000-000000000001'
\set lou 'c7a90000-0000-0000-0000-000000000002'
\set ray 'c7a90000-0000-0000-0000-000000000003'
\set sam 'c7a90000-0000-0000-0000-000000000004'

-- Everything below is rolled back at the end.
begin;
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@taps.test', '{"full_name": "Pat Owner"}'),
  (:'lou', 'lou@taps.test', '{"full_name": "Lou Lead"}'),
  (:'ray', 'ray@taps.test', '{"full_name": "Ray Crew"}'),
  (:'sam', 'sam@taps.test', '{"full_name": "Sam Crew"}');
set local role authenticated;
select tct.as_user(:'pat');
select public.create_company('Tap Tree Care', 'general') as co \gset
reset role;
select tct.as_nobody();
insert into public.memberships (company_id, user_id, role) values (:'co', :'lou', 'crew_lead'), (:'co', :'ray', 'field_crew'), (:'co', :'sam', 'field_crew');
insert into public.crews (company_id, name, lead_user_id) values (:'co', 'Climbers', :'lou') returning id as crew \gset
insert into public.crew_members (company_id, crew_id, user_id) values (:'co', :'crew', :'ray'), (:'co', :'crew', :'sam');
-- Fixed moments earlier today: the checks count minutes from t0.
select date_trunc('minute', now()) - interval '6 hours' as t0 \gset

\o
\echo 'Clock taps sent late'
\o /dev/null

-- Ray's morning with no signal, sent in the order he tapped: Driving at 0:00, Shop time at 1:00, Stop at 2:00.
set local role authenticated;
select tct.as_user(:'ray');
update public.time_entries set ended_at = :'t0', out_place = '{"lat": 40.1, "lng": -75.1, "accuracy": 12}' where company_id = :'co' and user_id in (:'ray') and ended_at is null and started_at < :'t0';
insert into public.time_entries (id, company_id, user_id, category, started_at, in_place) values ('c7a90000-0000-0000-0001-000000000001', :'co', :'ray', 'drive', :'t0', '{"lat": 40.1, "lng": -75.1, "accuracy": 12}');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '1 hour', out_place = '{"missing": "denied"}' where company_id = :'co' and user_id in (:'ray') and ended_at is null and started_at < :'t0'::timestamptz + interval '1 hour';
insert into public.time_entries (id, company_id, user_id, category, started_at, in_place) values ('c7a90000-0000-0000-0001-000000000002', :'co', :'ray', 'shop', :'t0'::timestamptz + interval '1 hour', '{"missing": "denied"}');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '2 hours' where company_id = :'co' and user_id in (:'ray') and ended_at is null and started_at < :'t0'::timestamptz + interval '2 hours';
select tct.check(tct.day_of(:'ray', :'t0') = 'drive 0-60, shop 60-120', 'taps sent hours later land where they were made, in order: a clock under the phone''s own id, each ending where the next began');

-- The same Start sent again (the app closed before it heard back): refused for its id, and nothing else moves.
insert into public.time_entries (id, company_id, user_id, category, started_at) values ('c7a90000-0000-0000-0001-000000000003', :'co', :'ray', 'other', :'t0'::timestamptz + interval '3 hours');
select tct.error_of(format('insert into public.time_entries (id, company_id, user_id, category, started_at) values (%L, %L, %L, %L, %L)', 'c7a90000-0000-0000-0001-000000000002', :'co', :'ray', 'shop', :'t0'::timestamptz + interval '1 hour')) as again \gset
select tct.check(:'again' like '23505:%time_entries_pkey%', 'a clock sent again under the same id is turned away as already there');
select tct.check(tct.day_of(:'ray', :'t0') = 'drive 0-60, shop 60-120, other 180-', 'and the clock running now is left running');
select tct.check((select count(*) = 1 from public.time_entries where id = 'c7a90000-0000-0000-0001-000000000002'), 'the phone can see it''s there, so it doesn''t send it at all');

-- A Stop tapped at 2:30, sent after the clock that started at 3:00: it ends nothing.
update public.time_entries set ended_at = :'t0'::timestamptz + interval '150 minutes' where company_id = :'co' and user_id in (:'ray') and ended_at is null and started_at < :'t0'::timestamptz + interval '150 minutes';
select tct.check(tct.day_of(:'ray', :'t0') = 'drive 0-60, shop 60-120, other 180-', 'a Stop never ends a clock that started after it was tapped');

-- A start from 2:15 that arrives now, with that newer clock running: saved up to where it began.
insert into public.time_entries (id, company_id, user_id, category, started_at, in_place) values ('c7a90000-0000-0000-0001-000000000004', :'co', :'ray', 'drive', :'t0'::timestamptz + interval '135 minutes', '{"lat": 40.2, "lng": -75.2, "accuracy": 30}');
select tct.check(tct.day_of(:'ray', :'t0') = 'drive 0-60, shop 60-120, drive 135-180, other 180-', 'a start that arrives after a newer clock is saved up to where that one began');
select tct.check((select count(*) = 1 from public.time_entries where user_id = :'ray' and ended_at is null)
  and not exists (select 1 from public.time_entries where user_id = :'ray' and ended_at <= started_at)
  and not exists (select 1 from public.time_entries a join public.time_entries b on a.user_id = b.user_id and a.id < b.id
    where a.user_id = :'ray' and a.started_at < coalesce(b.ended_at, 'infinity') and b.started_at < coalesce(a.ended_at, 'infinity')),
  'through all of it: one clock running, nothing ends before it starts, and no time is counted twice');

-- The crew lead's phone: everyone in with one tap, each under its own id, and out with another.
select tct.as_user(:'lou');
insert into public.time_entries (id, company_id, user_id, category, started_at) values
  ('c7a90000-0000-0000-0002-000000000001', :'co', :'lou', 'shop', :'t0'::timestamptz + interval '4 hours'),
  ('c7a90000-0000-0000-0002-000000000002', :'co', :'ray', 'shop', :'t0'::timestamptz + interval '4 hours'),
  ('c7a90000-0000-0000-0002-000000000003', :'co', :'sam', 'shop', :'t0'::timestamptz + interval '4 hours');
select tct.check((select count(*) = 3 from public.time_entries where company_id = :'co' and ended_at is null and category = 'shop'), 'a crew lead clocks the crew in under ids their phone made');
select tct.check(tct.day_of(:'ray', :'t0') = 'drive 0-60, shop 60-120, drive 135-180, other 180-240, shop 240-', 'which stops what each was on, then');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '5 hours' where company_id = :'co' and user_id in (:'lou', :'ray', :'sam') and ended_at is null and started_at < :'t0'::timestamptz + interval '5 hours';
select tct.check((select count(*) = 0 from public.time_entries where company_id = :'co' and ended_at is null), 'and out again with one statement');
-- Not someone outside their crew, whatever id is sent.
select tct.check(tct.error_of(format('insert into public.time_entries (id, company_id, user_id, category, started_at) values (%L, %L, %L, %L, %L)', 'c7a90000-0000-0000-0002-000000000009', :'co', :'pat', 'shop', :'t0'::timestamptz + interval '5 hours')) like '42501:%',
  'a crew lead still can''t clock in someone who isn''t on their crew');

rollback;

\o
\echo 'All clock tap tests passed.'
