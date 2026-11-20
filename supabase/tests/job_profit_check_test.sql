-- Database tests for the hourly job profit check's later fixes:
--   20261113001687_profit_check_counts_pay_as_the_job_page.sql   one sum of a job's sub and crew
--     pay, read by the job page (job_pay_costs) and by the check (job_pay_costs_for_check) alike.
--   20261113001688_first_profit_look_is_quiet.sql   a job's first look after the margin is set or
--     changed only lists it, whatever brought it in (a timesheet approval too); a later fall tells.
--   20261113001689_profit_check_loose_ends.sql   a margin too large to keep is kept as the nearest
--     that fits, a job's standing is made and locked before it's read, and a changed pay rate notes
--     the jobs it re-costs.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_jpc;
grant usage on schema t_jpc to authenticated, service_role;
create sequence t_jpc.passed;
grant usage on sequence t_jpc.passed to authenticated, service_role;
create function t_jpc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('t_jpc.passed');
  raise notice 'ok - %', p_what;
end $$;
create function t_jpc.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function t_jpc.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
grant execute on all functions in schema t_jpc to authenticated, service_role;
-- What the job page was told, kept to set beside what the check is told.
create table t_jpc.page_says (job_id uuid, amount numeric, payees integer);
grant all on t_jpc.page_says to authenticated, service_role;

\set mara 'c0614000-0000-0000-0000-000000000001'
\set milo 'c0614000-0000-0000-0000-000000000002'
\set moe 'c0614000-0000-0000-0000-000000000003'

-- Mara owns Maple Paving; Milo is in its office; Moe is on the crew, and paid by the job.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'mara', 'mara@maple-paving.test', '{"full_name": "Mara Maple"}'),
  (:'milo', 'milo@maple-paving.test', '{"full_name": "Milo Maple"}'),
  (:'moe', 'moe@maple-paving.test', '{"full_name": "Moe Maple"}');
begin;
set local role authenticated;
select t_jpc.as_user(:'mara');
select public.create_company('Maple Paving', 'paving') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', :'milo', 'office'), (:'co', :'moe', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Mia Maple') returning id as client \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Maple lot') returning id as job \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Maple drive') returning id as job2 \gset
insert into public.job_line_items (company_id, job_id, name, quantity, unit_price, unit_cost) values (:'co', :'job', 'Paving', 1, 10000, 1000), (:'co', :'job2', 'Paving', 1, 4000, 500);
commit;

-- ===== One sum of a job's pay, for the job page and for the hourly check =======================
-- Moe agreed to $7,500 for the lot, then was offered $6,500 and hasn't answered: what was agreed is
-- kept (accepted_snapshot) and is what the job costs until he does. On the drive he's been paid $900.
-- (Written straight in, as the offers' own functions would leave them.)
set session_replication_role = replica;
insert into public.job_pay (company_id, job_id, user_id, status, total, accepted_snapshot) values (:'co', :'job', :'moe', 'offered', 6500, '{"total": 7500}');
insert into public.job_pay (company_id, job_id, user_id, status, total, earned_on, paid_at, paid_amount, method) values (:'co', :'job2', :'moe', 'paid', 1000, current_date, now(), 900, 'check');
set session_replication_role = origin;

begin;
set local role authenticated;
select t_jpc.as_user(:'milo');
insert into t_jpc.page_says select * from public.job_pay_costs(array[:'job', :'job2']::uuid[]);
select t_jpc.check((select amount = 7500 and payees = 1 from t_jpc.page_says where job_id = :'job') and (select amount = 900 from t_jpc.page_says where job_id = :'job2'),
  'the job page counts a re-offered price at the $7,500 agreed, and paid work at the $900 paid');
select t_jpc.check(t_jpc.error_of(format('select * from public.job_pay_costs_for_check(%L, %L)', :'co', array[:'job']::uuid[])) like '42501:%', 'the check''s own way in is the server''s alone');
commit;
set role service_role;
select t_jpc.check((select count(*) = 2 from public.job_pay_costs_for_check(:'co', array[:'job', :'job2']::uuid[]))
  and not exists (select job_id, amount, payees from public.job_pay_costs_for_check(:'co', array[:'job', :'job2']::uuid[]) except select job_id, amount, payees from t_jpc.page_says)
  and not exists (select job_id, amount, payees from t_jpc.page_says except select job_id, amount, payees from public.job_pay_costs_for_check(:'co', array[:'job', :'job2']::uuid[])),
  'the hourly check is given exactly what the job page is, the same jobs fed to both');
select t_jpc.check(not exists (select from public.job_pay_costs_for_check(gen_random_uuid(), array[:'job']::uuid[])), 'and only for the company it''s checking');
reset role;
begin;
set local role authenticated;
select t_jpc.as_user(:'moe');
select t_jpc.check(not exists (select from public.job_pay_costs(array[:'job']::uuid[])), 'the crew still isn''t told what a job''s pay comes to');
commit;

-- ===== The first look after the margin is set is quiet, whatever brings the job in ============
-- Told about a job, as "who" lines; and how many job profit notices there are for it.
create function t_jpc.told(p_job uuid) returns bigint language sql stable as $$
  select count(*) from public.notifications where kind = 'job_profit' and link = '/jobs/' || p_job
$$;
grant execute on function t_jpc.told(uuid) to authenticated, service_role;
-- The drive was finished and closed before anyone set a margin.
update public.jobs set status = 'completed' where id = :'job2';
begin;
set local role authenticated;
select t_jpc.as_user(:'mara');
select public.merge_company_settings(:'co', '{"profit_alert_percent": 20}');
commit;
delete from private.job_cost_changes where company_id = :'co';
-- The quiet look after the margin is set: the open job only.
set role service_role;
select t_jpc.check((select sweep from public.profit_alert_companies() where company_id = :'co'), 'a margin just set means a quiet look at the open jobs');
select t_jpc.check((select count(*) = 1 and bool_and(job_id = :'job') from public.profit_alert_jobs(:'co', true)), 'which takes in the open lot, not the finished drive');
select t_jpc.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job', 'below', true, 'margin', 15, 'tell', false))) = 0, 'the open job below it is listed, not told');
select public.finish_profit_sweep(:'co', 20);
reset role;
-- A week's timesheets are approved: the rate each entry was approved at is written on it, which
-- notes its job, finished or not.
insert into public.time_entries (company_id, job_id, user_id, started_at, ended_at) values (:'co', :'job2', :'moe', now() - interval '9 hours', now() - interval '1 hour') returning id as entry \gset
delete from private.job_cost_changes where company_id = :'co';
update public.time_entries set labor_rate = 60 where id = :'entry';
select t_jpc.check(exists (select from private.job_cost_changes where job_id = :'job2'), 'approving time on the finished drive notes it for the check');
set role service_role;
select t_jpc.check((select not sweep from public.profit_alert_companies() where company_id = :'co'), 'the margin hasn''t changed, so this isn''t a quiet look');
-- The server finds it below, and (never having seen it below) says to tell.
select t_jpc.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job2', 'below', true, 'margin', 12, 'tell', true, 'title', 'Job is at 12% profit, below your 20%'))) = 0,
  'a finished job first looked at because its timesheet was approved tells nobody');
reset role;
select t_jpc.check(t_jpc.told(:'job2') = 0 and (select below and told_at is null and line = 20 from public.job_profit_alerts where job_id = :'job2'), 'it''s listed under Below your margin instead');
set role service_role;
select t_jpc.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job2', 'below', true, 'margin', 9, 'tell', true, 'title', 'again'))) = 0, 'still below at the next look: still nobody');
-- It comes back above the line, and later falls below again: that is news.
select public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job2', 'below', false, 'margin', 31, 'tell', false)));
select t_jpc.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job2', 'below', true, 'margin', 8, 'tell', true, 'title', 'Job is at 8% profit, below your 20%'))) = 1,
  'once it has been above the line, falling below it tells');
reset role;
select t_jpc.check(t_jpc.told(:'job2') = 2 and (select told_at is not null from public.job_profit_alerts where job_id = :'job2'), 'the owner and the office are told, once each');
-- A job made after the margin took effect was never listed: the first time it's found below, people are told.
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Maple walk') returning id as job3 \gset
set role service_role;
select t_jpc.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job3', 'below', true, 'margin', 3, 'tell', true, 'title', 'Job is at 3% profit, below your 20%'))) = 1,
  'a job made since the margin was set is told about the first time it''s found below');
reset role;
-- The margin changes: the next look at every job is quiet again, the finished one included.
begin;
set local role authenticated;
select t_jpc.as_user(:'mara');
select public.merge_company_settings(:'co', '{"profit_alert_percent": 30}');
commit;
update public.job_profit_alerts set below = false where job_id in (:'job2', :'job3');
set role service_role;
select t_jpc.check((select sweep and line = 30 from public.profit_alert_companies() where company_id = :'co'), 'a changed margin means a quiet look again');
-- Before that look has finished, a timesheet approval brings the finished job in: quiet.
select t_jpc.check(public.record_profit_checks(:'co', 30, jsonb_build_array(jsonb_build_object('job_id', :'job2', 'below', true, 'margin', 25, 'tell', true, 'title', 'x'))) = 0,
  'while the new margin''s quiet look is still going, nothing is told');
select public.finish_profit_sweep(:'co', 30);
select t_jpc.check(public.record_profit_checks(:'co', 30, jsonb_build_array(jsonb_build_object('job_id', :'job3', 'below', true, 'margin', 3, 'tell', true, 'title', 'x'))) = 0,
  'and a job last looked at under the old margin is first listed under the new one');
reset role;
select t_jpc.check(t_jpc.told(:'job2') = 2 and t_jpc.told(:'job3') = 2, 'so nobody heard anything more');

-- ===== Loose ends (20261113001689_profit_check_loose_ends.sql) ================================
-- A job priced at a cent with real costs: millions of percent under. It's kept, not an error that
-- undoes the whole company's check.
set role service_role;
select t_jpc.check(t_jpc.error_of(format('select public.record_profit_checks(%L, 30, %L)', :'co',
    jsonb_build_array(jsonb_build_object('job_id', :'job', 'below', true, 'margin', -11199900, 'tell', false), jsonb_build_object('job_id', :'job2', 'below', false, 'margin', 99999999999, 'tell', false)))) is null,
  'a margin past what can be kept doesn''t stop the check');
reset role;
select t_jpc.check((select margin = -9999999.9 from public.job_profit_alerts where job_id = :'job') and (select margin = 9999999.9 from public.job_profit_alerts where job_id = :'job2'),
  'it''s kept as the nearest margin that fits');
-- A new job's standing is made (and locked) before it's read, so a second check at the same moment
-- waits for the first and finds the job already told about.
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Maple steps') returning id as job4 \gset
set role service_role;
select t_jpc.check(public.record_profit_checks(:'co', 30, jsonb_build_array(jsonb_build_object('job_id', :'job4', 'below', true, 'margin', 2, 'tell', true, 'title', 'Job is at 2% profit, below your 30%'))) = 1,
  'a new job found below is told about');
select t_jpc.check(public.record_profit_checks(:'co', 30, jsonb_build_array(jsonb_build_object('job_id', :'job4', 'below', true, 'margin', 2, 'tell', true, 'title', 'Job is at 2% profit, below your 30%'))) = 0,
  'and the check that comes second, having decided the same from the same reading, tells nobody again');
reset role;
select t_jpc.check(t_jpc.told(:'job4') = 2 and (select count(*) = 1 and bool_and(below and line = 30 and told_at is not null) from public.job_profit_alerts where job_id = :'job4'),
  'one notice each for the owner and the office, and one standing');
-- A pay rate changes: the jobs with that person's time not approved yet cost something else now.
insert into public.time_entries (company_id, job_id, user_id, started_at, ended_at) values (:'co', :'job', :'moe', now() - interval '5 hours', now() - interval '1 hour');
delete from private.job_cost_changes where company_id = :'co';
update public.memberships set labor_rate = 42 where company_id = :'co' and user_id = :'moe';
select t_jpc.check((select string_agg(case job_id when :'job' then 'lot' when :'job2' then 'drive' else 'other' end, ',') from private.job_cost_changes where company_id = :'co') = 'lot',
  'a changed pay rate notes the job with that person''s unapproved time, and not the one whose time was approved at its own rate');
delete from private.job_cost_changes where company_id = :'co';
update public.memberships set labor_rate = 42 where company_id = :'co' and user_id = :'moe';
update public.memberships set labor_rate = 55 where company_id = :'co' and user_id = :'mara';
select t_jpc.check(not exists (select from private.job_cost_changes where company_id = :'co'), 'a rate saved unchanged, or someone else''s, notes nothing');

\o
select format('All %s job-profit-check checks passed.', last_value) from t_jpc.passed \gset
\echo :format
