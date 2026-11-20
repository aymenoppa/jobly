-- Database tests for 20261113000120_closed_jobs_leave_the_schedule.sql: a job that's closed or
-- archived loses the visits its schedule made that are still to come and untouched, however it was
-- closed; visits with work logged, started, past, finished or added by hand stay; the removed ones
-- aren't remembered as deleted, so a reopened job gets them back; and the job's page can ask how
-- many will go.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tcj;
grant usage on schema tcj to authenticated, service_role;
create function tcj.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tcj.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- The server, or the test's own shortcuts: nobody signed in.
create function tcj.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
-- A weekly job for a client with one $45 line.
create function tcj.weekly(p_company uuid, p_client uuid, p_title text) returns uuid language plpgsql as $$
declare v_job uuid;
begin
  insert into public.jobs (company_id, client_id, title, kind, recurrence_rule, starts_on)
  values (p_company, p_client, p_title, 'recurring', 'FREQ=WEEKLY;INTERVAL=1', private.company_today(p_company) - 14) returning id into v_job;
  insert into public.job_line_items (company_id, job_id, name, unit_price) values (p_company, v_job, 'Mowing', 45);
  return v_job;
end $$;
-- A visit the job's schedule made for a day (p_days from the company's today), as the nightly run makes them.
create function tcj.made(p_company uuid, p_job uuid, p_days integer, p_status text default 'scheduled') returns uuid language plpgsql as $$
declare v_visit uuid; v_on date := private.company_today(p_company) + p_days;
begin
  insert into public.visits (company_id, job_id, title, status, scheduled_on, recurrence_key) values (p_company, p_job, 'Mow', p_status, v_on, v_on::text)
  returning id into v_visit;
  return v_visit;
end $$;
-- A job's visits left, as the days from today they're on, in order.
create function tcj.days(p_job uuid) returns text language sql as $$
  select coalesce(string_agg((v.scheduled_on - private.company_today(v.company_id))::text, ',' order by v.scheduled_on), '')
  from public.visits v where v.job_id = p_job
$$;
grant execute on all functions in schema tcj to authenticated, service_role;

\set olive 'c105ed00-0000-0000-0000-000000000001'
\set opal 'c105ed00-0000-0000-0000-000000000002'
\set cy 'c105ed00-0000-0000-0000-000000000003'
\set pat 'c105ed00-0000-0000-0000-000000000004'

-- Everything below is rolled back at the end.
begin;
-- Olive owns Closing Time Lawns; Opal is in the office; Cy is field crew. Pat owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'olive', 'olive@closing.test', '{"full_name": "Olive Owner"}'),
  (:'opal', 'opal@closing.test', '{"full_name": "Opal Office"}'),
  (:'cy', 'cy@closing.test', '{"full_name": "Cy Crew"}'),
  (:'pat', 'pat@closing.test', '{"full_name": "Pat Other"}');
set local role authenticated;
select tcj.as_user(:'pat');
select public.create_company('Closing Time Paving', 'paving') as other \gset
select tcj.as_user(:'olive');
select public.create_company('Closing Time Lawns', 'lawn_exterior') as co \gset
reset role;
select tcj.as_nobody();
insert into public.memberships (company_id, user_id, role) values (:'co', :'opal', 'office'), (:'co', :'cy', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Lena Lawn') returning id as lena \gset

-- ===== Archiving ================================================================================
-- Three visits to come that nobody touched (today, next week, the week after), and one each that
-- stays: missed last week, finished two weeks ago, started today, with time on it, with materials,
-- with a checklist answered, covered by crew pay whose work is done, and one added by hand.
select tcj.weekly(:'co', :'lena', 'Weekly mow') as j1 \gset
select tcj.made(:'co', :'j1', -14, 'completed') as v_done \gset
select tcj.made(:'co', :'j1', -7) as v_missed \gset
select tcj.made(:'co', :'j1', 0) as v_today \gset
select tcj.made(:'co', :'j1', 7) as v_next \gset
select tcj.made(:'co', :'j1', 14) as v_later \gset
select tcj.made(:'co', :'j1', 1, 'in_progress') as v_started \gset
select tcj.made(:'co', :'j1', 21) as v_time \gset
select tcj.made(:'co', :'j1', 28) as v_material \gset
select tcj.made(:'co', :'j1', 35) as v_checklist \gset
select tcj.made(:'co', :'j1', 42) as v_pay \gset
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'j1', 'Extra trim', private.company_today(:'co') + 3) returning id as v_hand \gset
insert into public.time_entries (company_id, user_id, visit_id, job_id, started_at, ended_at) values (:'co', :'cy', :'v_time', :'j1', now() - interval '2 hours', now() - interval '1 hour');
insert into public.job_materials (company_id, job_id, visit_id, name, quantity, unit) values (:'co', :'j1', :'v_material', 'Mulch', 2, 'yd');
insert into public.checklist_responses (company_id, visit_id, answers) values (:'co', :'v_checklist', '{"gate": true}');
insert into public.job_pay (company_id, job_id, user_id) values (:'co', :'j1', :'cy') returning id as pay \gset
insert into public.job_pay_visits (company_id, job_pay_id, visit_id) values (:'co', :'pay', :'v_pay');
update public.job_pay set status = 'accepted' where id = :'pay';
update public.job_pay set status = 'done', earned_on = private.company_today(:'co') where id = :'pay';
-- A visit Opal deleted by hand earlier stays deleted, whatever happens to the job.
select tcj.made(:'co', :'j1', 49) as v_gone \gset
set local role authenticated;
select tcj.as_user(:'opal');
delete from public.visits where id = :'v_gone';
select tcj.check(public.job_visits_to_remove(:'j1') = 3, 'the job''s page is told three visits would go');
select tcj.as_user(:'cy');
select tcj.check(public.job_visits_to_remove(:'j1') = 0, 'crew aren''t told');
select tcj.as_user(:'pat');
select tcj.check(public.job_visits_to_remove(:'j1') = 0, 'nor another business');
select tcj.as_user(:'opal');
update public.jobs set status = 'requires_invoicing' where id = :'j1';
reset role;
select tcj.as_nobody();
select tcj.check(tcj.days(:'j1') = '-14,-7,0,1,3,7,14,21,28,35,42', 'marking the work complete leaves its visits where they are');
set local role authenticated;
select tcj.as_user(:'opal');
update public.jobs set status = 'archived' where id = :'j1';
reset role;
select tcj.as_nobody();
select tcj.check(tcj.days(:'j1') = '-14,-7,1,3,21,28,35,42',
  'archiving it removes the untouched visits to come, and keeps the finished, missed, started, logged-on, paid-for and hand-added ones');
select tcj.check((select string_agg(recurrence_key, ',') from public.recurrence_skips where job_id = :'j1') = (private.company_today(:'co') + 49)::text,
  'the removed visits aren''t remembered as deleted, so reopening brings them back; the one deleted by hand still is');
select tcj.check(public.job_visits_to_remove(:'j1') = 0, 'and there are none left to remove');

-- ===== Closing ==================================================================================
select tcj.weekly(:'co', :'lena', 'Hedges') as j2 \gset
select tcj.made(:'co', :'j2', -7, 'completed') as h_done \gset
select tcj.made(:'co', :'j2', 7) as h_next \gset
set local role authenticated;
select tcj.as_user(:'opal');
update public.jobs set status = 'requires_invoicing' where id = :'j2';
select public.create_invoice_for_job(:'j2', 'visits') as j2_invoice \gset
reset role;
select tcj.as_nobody();
select tcj.check((select status from public.jobs where id = :'j2') = 'completed' and tcj.days(:'j2') = '-7',
  'an invoice closing the job takes its waiting visits off too');
select tcj.check(not exists (select 1 from public.recurrence_skips where job_id = :'j2'), 'without remembering them as deleted');

-- The server closing a job (nobody signed in) does the same.
select tcj.weekly(:'co', :'lena', 'Leaves') as j3 \gset
select tcj.made(:'co', :'j3', 7) as l_next \gset
update public.jobs set status = 'completed' where id = :'j3';
select tcj.check(tcj.days(:'j3') = '', 'a job closed by the server loses them as well');

-- ===== What stays ===============================================================================
select tcj.weekly(:'co', :'lena', 'Still going') as j4 \gset
select tcj.made(:'co', :'j4', 7) as g_next \gset
update public.jobs set title = 'Still going strong' where id = :'j4';
select tcj.check(tcj.days(:'j4') = '7', 'a job that stays active keeps its visits');
insert into public.jobs (company_id, client_id, title) values (:'co', :'lena', 'Patio') returning id as j5 \gset
insert into public.visits (company_id, job_id, title, scheduled_on) values (:'co', :'j5', 'Pour', private.company_today(:'co') + 5);
update public.jobs set status = 'archived' where id = :'j5';
select tcj.check(tcj.days(:'j5') = '5', 'a one-off job''s visits were all added by hand, and stay');
rollback;

\echo 'All closed job tests passed.'
