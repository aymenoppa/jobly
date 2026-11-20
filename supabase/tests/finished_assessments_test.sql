-- Database tests for 20261113000110_finished_assessments_mark_their_request.sql: finishing a
-- request's assessment visit marks the request Assessment done, once no other assessment for it is
-- open, and leaves a request that has moved on as it is.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tfa;
grant usage on schema tfa to authenticated, service_role;
create function tfa.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tfa.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- The server, or the test's own shortcuts: nobody signed in.
create function tfa.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
-- A request for a client, at a status.
create function tfa.request(p_company uuid, p_client uuid, p_title text, p_status text default 'assessment_scheduled') returns uuid language sql as $$
  insert into public.requests (company_id, client_id, title, status) values (p_company, p_client, p_title, p_status) returning id
$$;
-- An assessment visit for it today, with Eve (estimator) on it.
create function tfa.assessment(p_company uuid, p_request uuid, p_kind text default 'assessment') returns uuid language plpgsql as $$
declare v_visit uuid;
begin
  insert into public.visits (company_id, request_id, title, kind, scheduled_on) values (p_company, p_request, 'Look at the site', p_kind, private.company_today(p_company))
  returning id into v_visit;
  insert into public.visit_assignees (company_id, visit_id, user_id) values (p_company, v_visit, 'a55e5500-0000-0000-0000-000000000002');
  return v_visit;
end $$;
create function tfa.status(p_request uuid) returns text language sql as $$
  select status from public.requests where id = p_request
$$;
grant execute on all functions in schema tfa to authenticated, service_role;

\set olive 'a55e5500-0000-0000-0000-000000000001'
\set eve 'a55e5500-0000-0000-0000-000000000002'

-- Everything below is rolled back at the end.
begin;
-- Olive owns Assess First Roofing; Eve estimates.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'olive', 'olive@assess.test', '{"full_name": "Olive Owner"}'),
  (:'eve', 'eve@assess.test', '{"full_name": "Eve Estimator"}');
set local role authenticated;
select tfa.as_user(:'olive');
select public.create_company('Assess First Roofing', 'general') as co \gset
reset role;
select tfa.as_nobody();
insert into public.memberships (company_id, user_id, role) values (:'co', :'eve', 'estimator');
insert into public.clients (company_id, display_name) values (:'co', 'Rae Roof') returning id as rae \gset

select tfa.request(:'co', :'rae', 'Leak over the porch') as r1 \gset
select tfa.assessment(:'co', :'r1') as r1a \gset
select tfa.assessment(:'co', :'r1') as r1b \gset
set local role authenticated;
select tfa.as_user(:'eve');
update public.visits set status = 'in_progress' where id = :'r1a';
update public.visits set status = 'completed' where id = :'r1a';
reset role;
select tfa.as_nobody();
select tfa.check(tfa.status(:'r1') = 'assessment_scheduled', 'a request with another assessment still to do stays Assessment booked');
set local role authenticated;
select tfa.as_user(:'eve');
update public.visits set status = 'completed' where id = :'r1b';
reset role;
select tfa.as_nobody();
select tfa.check(tfa.status(:'r1') = 'assessment_complete', 'finishing its last assessment marks it Assessment done');

select tfa.request(:'co', :'rae', 'Booked online', 'new') as r2 \gset
select tfa.assessment(:'co', :'r2') as r2a \gset
select tfa.assessment(:'co', :'r2') as r2b \gset
update public.visits set status = 'cancelled' where id = :'r2b';
update public.visits set status = 'completed' where id = :'r2a';
select tfa.check(tfa.status(:'r2') = 'assessment_complete', 'a request still New is marked too, a cancelled assessment aside');

select tfa.request(:'co', :'rae', 'Already quoted', 'quoted') as r3 \gset
select tfa.assessment(:'co', :'r3') as r3a \gset
select tfa.request(:'co', :'rae', 'Put away', 'archived') as r4 \gset
select tfa.assessment(:'co', :'r4') as r4a \gset
select tfa.request(:'co', :'rae', 'Only a task', 'assessment_scheduled') as r5 \gset
select tfa.assessment(:'co', :'r5', 'task') as r5a \gset
update public.visits set status = 'completed' where id in (:'r3a', :'r4a', :'r5a');
select tfa.check(tfa.status(:'r3') = 'quoted' and tfa.status(:'r4') = 'archived', 'a request that''s quoted or archived stays as it is');
select tfa.check(tfa.status(:'r5') = 'assessment_scheduled', 'and only an assessment counts, not a task on the request');

-- An assessment logged as already completed: by someone signed in it counts, loaded by the server it doesn't.
select tfa.request(:'co', :'rae', 'Looked at last week', 'new') as r6 \gset
insert into public.visits (company_id, request_id, title, kind, status, scheduled_on) values (:'co', :'r6', 'Loaded', 'assessment', 'completed', current_date - 7);
select tfa.check(tfa.status(:'r6') = 'new', 'a finished assessment the server adds, with nobody signed in, changes nothing');
set local role authenticated;
select tfa.as_user(:'olive');
insert into public.visits (company_id, request_id, title, kind, status, scheduled_on) values (:'co', :'r6', 'Walked the roof', 'assessment', 'completed', current_date - 7);
reset role;
select tfa.as_nobody();
select tfa.check(tfa.status(:'r6') = 'assessment_complete', 'one the office logs as already completed marks the request');
rollback;

\echo 'All finished assessment tests passed.'
