-- Database tests for 20261113000600_finished_visits_end_their_clocks.sql: finishing a visit ends
-- every clock still running on it, for everyone clocked in and whoever finishes it, at the moment
-- it was finished (the tap's own time for one sent later); a clock-in that arrives after the visit
-- was finished ends there too; and what's left alone: other clocks, approved and paid time, later
-- time of the same person, a cancelled visit.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tfc;
grant usage on schema tfc to authenticated, service_role;
create function tfc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tfc.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tfc.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- The server, or the test's own shortcuts: nobody signed in.
create function tfc.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
-- A visit today with these people on it, under way.
create function tfc.visit(p_company uuid, p_job uuid, p_title text, p_people uuid[]) returns uuid language plpgsql as $$
declare v_visit uuid;
begin
  insert into public.visits (company_id, job_id, title, status, scheduled_on) values (p_company, p_job, p_title, 'in_progress', private.company_today(p_company))
  returning id into v_visit;
  insert into public.visit_assignees (company_id, visit_id, user_id) select p_company, v_visit, u from unnest(p_people) u;
  return v_visit;
end $$;
-- Someone's clock on a visit (or, with no visit, on something else), started then.
create function tfc.clock(p_company uuid, p_user uuid, p_visit uuid, p_started timestamptz, p_category text default 'visit') returns uuid language sql as $$
  insert into public.time_entries (company_id, user_id, visit_id, job_id, category, started_at)
  values (p_company, p_user, p_visit, (select job_id from public.visits where id = p_visit), p_category, p_started) returning id
$$;
create function tfc.ended(p_entry uuid) returns timestamptz language sql as $$
  select ended_at from public.time_entries where id = p_entry
$$;
-- How many clocks someone has running.
create function tfc.running(p_user uuid) returns integer language sql as $$
  select count(*)::integer from public.time_entries where user_id = p_user and ended_at is null
$$;
grant execute on all functions in schema tfc to authenticated, service_role;

\set pat 'fc100000-0000-0000-0000-000000000001'
\set ray 'fc100000-0000-0000-0000-000000000002'
\set sam 'fc100000-0000-0000-0000-000000000003'
\set tess 'fc100000-0000-0000-0000-000000000004'

-- Everything below is rolled back at the end.
begin;
-- Pat owns Clockwork Gutters; Ray, Sam and Tess are field crew.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@clockwork.test', '{"full_name": "Pat Owner"}'),
  (:'ray', 'ray@clockwork.test', '{"full_name": "Ray Crew"}'),
  (:'sam', 'sam@clockwork.test', '{"full_name": "Sam Crew"}'),
  (:'tess', 'tess@clockwork.test', '{"full_name": "Tess Crew"}');
set local role authenticated;
select tfc.as_user(:'pat');
select public.create_company('Clockwork Gutters', 'general') as co \gset
reset role;
select tfc.as_nobody();
-- On the clock that stops with the visit (visits only). The whole-day clock, which goes on to travel
-- instead, is in whole_day_clock_test.sql.
update public.companies set settings = jsonb_set(settings, '{clock}', '{"mode": "visits"}') where id = :'co';
insert into public.memberships (company_id, user_id, role) values (:'co', :'ray', 'field_crew'), (:'co', :'sam', 'field_crew'), (:'co', :'tess', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Maria Lopez') returning id as maria \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'maria', 'Gutters') returning id as job \gset
-- Fixed moments earlier today, so the checks can name them.
select date_trunc('minute', now()) - interval '5 hours' as t0 \gset

\o
\echo 'Finishing a visit ends the clocks running on it'
\o /dev/null

-- ===== Everyone clocked in on it, at the moment it was finished ================================
select tfc.visit(:'co', :'job', 'Front gutters', array[:'ray', :'sam', :'tess']::uuid[]) as v1 \gset
select tfc.visit(:'co', :'job', 'Back gutters', array[:'ray', :'sam', :'tess']::uuid[]) as v2 \gset
select tfc.clock(:'co', :'ray', :'v1', :'t0') as ray1 \gset
select tfc.clock(:'co', :'sam', :'v1', :'t0'::timestamptz + interval '10 minutes') as sam1 \gset
-- Tess is on the other visit.
select tfc.clock(:'co', :'tess', :'v2', :'t0') as tess2 \gset

-- Ray taps Complete: his phone sends when it was tapped, two hours in.
set local role authenticated;
select tfc.as_user(:'ray');
update public.visits set status = 'completed', completed_at = :'t0'::timestamptz + interval '2 hours' where id = :'v1';
reset role;
select tfc.as_nobody();
select tfc.check(tfc.ended(:'sam1') = :'t0'::timestamptz + interval '2 hours', 'a crewmate who didn''t tap Complete is clocked out when the visit was finished');
select tfc.check(tfc.ended(:'ray1') = :'t0'::timestamptz + interval '2 hours', 'and so is whoever tapped it, if their phone hadn''t stopped their clock yet');
select tfc.check(tfc.ended(:'tess2') is null and tfc.running(:'tess') = 1, 'a clock on another visit keeps running');
select tfc.check((select auto_stopped_at is null and approved_at is null from public.time_entries where id = :'sam1'), 'it''s ordinary time, not marked as stopped for them');

-- ===== A Complete that arrives late, and clocks that started after it was tapped ================
select tfc.visit(:'co', :'job', 'Downspouts', array[:'ray', :'sam']::uuid[]) as v3 \gset
select tfc.clock(:'co', :'ray', :'v3', :'t0'::timestamptz + interval '2 hours') as ray3 \gset
-- Sam clocked in on it after Ray tapped Complete with no signal (Sam's phone still showed it under way).
select tfc.clock(:'co', :'sam', :'v3', :'t0'::timestamptz + interval '4 hours') as sam3 \gset
set local role authenticated;
select tfc.as_user(:'ray');
update public.visits set status = 'completed', completed_at = :'t0'::timestamptz + interval '3 hours' where id = :'v3';
reset role;
select tfc.as_nobody();
select tfc.check(tfc.ended(:'ray3') = :'t0'::timestamptz + interval '3 hours', 'a Complete sent later ends the clocks when it was tapped, not when it arrived');
select tfc.check(tfc.ended(:'sam3') > :'t0'::timestamptz + interval '4 hours' and tfc.ended(:'sam3') <= now(), 'a clock that started after the tap ends when the Complete arrives, never before it began');

-- A clock-in that arrives after the visit was finished (Tess tapped Start with no signal, 2 h 30 in).
set local role authenticated;
select tfc.as_user(:'tess');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '2 hours 30 minutes' where id = :'tess2';
insert into public.time_entries (company_id, user_id, visit_id, job_id, category, started_at) values (:'co', :'tess', :'v3', :'job', 'visit', :'t0'::timestamptz + interval '2 hours 30 minutes') returning id as tess3 \gset
select tfc.check(tfc.ended(:'tess3') = :'t0'::timestamptz + interval '3 hours' and tfc.running(:'tess') = 0, 'a clock-in that arrives after the visit was finished, dated before it, ends when the visit was finished');
-- One dated after it was finished is the person's own doing, and stays theirs to stop.
insert into public.time_entries (company_id, user_id, visit_id, job_id, category, started_at) values (:'co', :'tess', :'v3', :'job', 'visit', :'t0'::timestamptz + interval '4 hours') returning id as tess3b \gset
select tfc.check(tfc.ended(:'tess3b') is null, 'a clock started on it after it was finished keeps running');
update public.time_entries set ended_at = :'t0'::timestamptz + interval '4 hours 5 minutes' where id = :'tess3b';
-- Finished time added on a finished visit is nobody's clock.
insert into public.time_entries (company_id, user_id, visit_id, job_id, category, started_at, ended_at)
values (:'co', :'tess', :'v1', :'job', 'visit', :'t0'::timestamptz + interval '1 hour', :'t0'::timestamptz + interval '2 hours 20 minutes');
select tfc.check((select ended_at = :'t0'::timestamptz + interval '2 hours 20 minutes' from public.time_entries where user_id = :'tess' and visit_id = :'v1'), 'finished time added on a finished visit is saved as given');
reset role;
select tfc.as_nobody();
delete from public.time_entries where company_id = :'co';

-- ===== Whoever finishes it, and however =========================================================
select tfc.visit(:'co', :'job', 'Fascia', array[:'ray', :'sam']::uuid[]) as v4 \gset
select tfc.clock(:'co', :'ray', :'v4', :'t0') as ray4 \gset
select tfc.clock(:'co', :'sam', :'v4', :'t0') as sam4 \gset
-- The office, from the schedule: no time of its own, so the visit is finished now.
set local role authenticated;
select tfc.as_user(:'pat');
update public.visits set status = 'completed' where id = :'v4';
select tfc.check(tfc.ended(:'ray4') = (select completed_at from public.visits where id = :'v4') and tfc.ended(:'sam4') = tfc.ended(:'ray4'), 'the office finishing a visit clocks out everyone on it, then');
-- Reopened and finished again: the visit keeps its first date, and a clock started since ends now.
update public.visits set status = 'in_progress' where id = :'v4';
reset role;
select tfc.as_nobody();
select tfc.clock(:'co', :'ray', :'v4', now() - interval '1 minute') as ray4b \gset
select tfc.clock(:'co', :'sam', :'v4', now() - interval '2 minutes') as sam4b \gset
update public.visits set status = 'completed' where id = :'v4';
select tfc.check(tfc.ended(:'ray4b') > now() - interval '1 minute' and tfc.ended(:'ray4b') <= now(), 'a visit finished a second time ends its clocks now, not at its first date');
select tfc.check(tfc.ended(:'sam4b') = tfc.ended(:'ray4b'), 'the server finishing a visit (nobody signed in) ends them too');
delete from public.time_entries where company_id = :'co';

-- A cancelled visit isn't a finished one.
select tfc.visit(:'co', :'job', 'Soffit', array[:'ray']::uuid[]) as v5 \gset
select tfc.clock(:'co', :'ray', :'v5', :'t0') as ray5 \gset
update public.visits set status = 'cancelled' where id = :'v5';
select tfc.check(tfc.ended(:'ray5') is null, 'cancelling a visit leaves its clocks as they are');
delete from public.time_entries where company_id = :'co';

-- ===== What it never does ======================================================================
select tfc.visit(:'co', :'job', 'Gutter guards', array[:'ray', :'sam', :'tess']::uuid[]) as v6 \gset
-- Ray: later time already on record (the office added his afternoon at the shop).
select tfc.clock(:'co', :'ray', :'v6', :'t0') as ray6 \gset
insert into public.time_entries (company_id, user_id, category, started_at, ended_at) values (:'co', :'ray', 'shop', :'t0'::timestamptz + interval '1 hour', :'t0'::timestamptz + interval '90 minutes');
-- Sam: the office approved his running clock.
select tfc.clock(:'co', :'sam', :'v6', :'t0') as sam6 \gset
update public.time_entries set approved_at = now(), approved_by = :'pat' where id = :'sam6';
-- Tess: marked paid for a period with today in it.
select tfc.clock(:'co', :'tess', :'v6', :'t0') as tess6 \gset
insert into public.pay_periods (company_id, starts_on, ends_on) values (:'co', private.company_today(:'co') - 7, private.company_today(:'co') + 1) returning id as period \gset
insert into public.pay_period_lines (company_id, period_id, user_id, hours, amount, paid_amount, method, paid_at) values (:'co', :'period', :'tess', 0, 0, 0, 'check', now());
-- A phone whose clock runs fast: started "five minutes from now".
select tfc.visit(:'co', :'job', 'Leaf screens', array[:'ray']::uuid[]) as v7 \gset

set local role authenticated;
select tfc.as_user(:'pat');
select tfc.error_of(format('update public.visits set status = %L, completed_at = %L where id = %L', 'completed', :'t0'::timestamptz + interval '2 hours', :'v6')) as finished \gset
select tfc.check(:'finished' = 'none' and (select status = 'completed' from public.visits where id = :'v6'), 'the visit is finished whatever its clocks are');
select tfc.check(tfc.ended(:'ray6') = :'t0'::timestamptz + interval '1 hour', 'a clock ends where the person''s later time begins, not over it');
select tfc.check(not exists (select 1 from public.time_entries a join public.time_entries b on a.user_id = b.user_id and a.id < b.id
  where a.user_id = :'ray' and a.started_at < coalesce(b.ended_at, 'infinity') and b.started_at < coalesce(a.ended_at, 'infinity')), 'so none of their time overlaps');
select tfc.check(tfc.ended(:'sam6') is null, 'approved time is left as it was approved');
select tfc.check(tfc.ended(:'tess6') is null, 'time on a day the person was marked paid for is left as it was paid');
reset role;
select tfc.as_nobody();
select tfc.clock(:'co', :'ray', :'v7', now() + interval '5 minutes') as ray7 \gset
update public.visits set status = 'completed' where id = :'v7';
select tfc.check((select ended_at = started_at + interval '1 second' from public.time_entries where id = :'ray7'), 'a clock dated ahead of the server still ends after it starts');
select tfc.check(not exists (select 1 from public.time_entries where company_id = :'co' and ended_at <= started_at), 'and nothing is left with no length or less');

rollback;

\o
\echo 'All finished-visit clock tests passed.'
