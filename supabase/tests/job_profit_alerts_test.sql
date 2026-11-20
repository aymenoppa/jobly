-- Database tests for 20261113001200_job_profit_alerts.sql: the profit line is the company's setting,
-- set by owners and admins; the tables a job's costs are made of note the job as its costs change
-- (and only then); the hourly check's functions are the server's alone; a job going below the line
-- is told about once to the people who see job costs, and again only after it came back up; a new
-- line is swept quietly with one note; and turning it off forgets it all.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_jpa;
grant usage on schema t_jpa to authenticated, service_role;
create sequence t_jpa.passed;
grant usage on sequence t_jpa.passed to authenticated, service_role;
create function t_jpa.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('t_jpa.passed');
  raise notice 'ok - %', p_what;
end $$;
create function t_jpa.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
grant execute on all functions in schema t_jpa to authenticated, service_role;

-- Opal owns Onyx Paving; Otto is in its office; Oren is an office clerk whose role hasn't job costs;
-- Ola is on the crew.
insert into auth.users (id, email, raw_user_meta_data) values
  ('c0612000-0000-0000-0000-000000000001', 'opal@onyx-paving.test', '{"full_name": "Opal Onyx"}'),
  ('c0612000-0000-0000-0000-000000000002', 'otto@onyx-paving.test', '{"full_name": "Otto Onyx"}'),
  ('c0612000-0000-0000-0000-000000000003', 'oren@onyx-paving.test', '{"full_name": "Oren Onyx"}'),
  ('c0612000-0000-0000-0000-000000000004', 'ola@onyx-paving.test', '{"full_name": "Ola Onyx"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Onyx Paving', 'paving') as co \gset
insert into public.company_roles (company_id, name, base_role, permissions) values (:'co', 'Onyx clerk', 'office', '{sales,invoices}') returning id as clerk \gset
insert into public.memberships (company_id, user_id, role) values (:'co', 'c0612000-0000-0000-0000-000000000002', 'office'), (:'co', 'c0612000-0000-0000-0000-000000000004', 'field_crew');
insert into public.memberships (company_id, user_id, role, role_id) values (:'co', 'c0612000-0000-0000-0000-000000000003', 'office', :'clerk');
insert into public.clients (company_id, display_name) values (:'co', 'Maria Onyx') returning id as client \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Onyx drive') returning id as job \gset
insert into public.jobs (company_id, client_id, title, kind, recurrence_rule) values (:'co', :'client', 'Onyx weekly sweep', 'recurring', 'FREQ=WEEKLY') returning id as weekly \gset
insert into public.job_line_items (company_id, job_id, name, quantity, unit_price, unit_cost) values (:'co', :'job', 'Onyx sealcoat', 1, 1000, 300) returning id as line \gset
commit;

-- ===== The setting ============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select t_jpa.check(t_jpa.error_of(format('select public.merge_company_settings(%L, %L)', :'co', '{"profit_alert_percent": 20}')) like '42501:%', 'office staff can''t set the profit line');
commit;
select t_jpa.check(private.profit_alert_line(:'co') is null, 'it''s off until it''s set');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.merge_company_settings(:'co', '{"profit_alert_percent": "abc"}');
commit;
select t_jpa.check(private.profit_alert_line(:'co') is null, 'something that isn''t a whole percent leaves it off');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.merge_company_settings(:'co', '{"profit_alert_percent": 20}');
commit;
select t_jpa.check(private.profit_alert_line(:'co') = 20, 'the owner sets it to 20%');
select t_jpa.check((select array_agg(u order by u) from private.job_costs_office(:'co') u) = '{c0612000-0000-0000-0000-000000000001,c0612000-0000-0000-0000-000000000002}',
  'the people told are the owner and office staff with job costs, not a clerk without them or the crew');

-- ===== What changed ===========================================================================
delete from private.job_cost_changes where company_id = :'co';
insert into public.time_entries (company_id, user_id, job_id, started_at, ended_at) values (:'co', 'c0612000-0000-0000-0000-000000000004', :'job', now() - interval '3 hours', now()) returning id as te \gset
select t_jpa.check(exists (select from private.job_cost_changes where job_id = :'job' and company_id = :'co'), 'time on the job notes it');
select changed_at as first_change from private.job_cost_changes where job_id = :'job' \gset
update public.time_entries set notes = 'Swept the drive first' where id = :'te';
select t_jpa.check((select changed_at = :'first_change' from private.job_cost_changes where job_id = :'job'), 'a note on the time doesn''t');
delete from private.job_cost_changes;
update public.time_entries set labor_rate = 30 where id = :'te';
select t_jpa.check(exists (select from private.job_cost_changes where job_id = :'job'), 'its rate as it''s approved does');
delete from private.job_cost_changes;
insert into public.expenses (company_id, job_id, amount, user_id) values (:'co', :'job', 50, 'c0612000-0000-0000-0000-000000000001') returning id as expense \gset
select t_jpa.check(exists (select from private.job_cost_changes where job_id = :'job'), 'an expense does');
delete from private.job_cost_changes;
update public.expenses set description = 'Crack filler' where id = :'expense';
select t_jpa.check(not exists (select from private.job_cost_changes), 'its description doesn''t');
update public.expenses set job_id = :'weekly' where id = :'expense';
select t_jpa.check((select count(*) = 2 from private.job_cost_changes where job_id in (:'job', :'weekly')), 'moved to another job, both jobs are noted');
delete from private.job_cost_changes;
insert into public.job_materials (company_id, job_id, name, quantity, unit, logged_by) values (:'co', :'job', 'Sealer', 30, 'gal', 'c0612000-0000-0000-0000-000000000001');
select t_jpa.check(exists (select from private.job_cost_changes where job_id = :'job'), 'a logged material does');
delete from private.job_cost_changes;
update public.job_line_items set unit_price = 900 where id = :'line';
select t_jpa.check(exists (select from private.job_cost_changes where job_id = :'job'), 'a new price on a line does');

-- ===== The server's functions ==================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select t_jpa.check(t_jpa.error_of('select * from public.profit_alert_companies()') like '42501:%', 'the owner can''t run the hourly check''s functions');
select t_jpa.check(t_jpa.error_of(format('select public.record_profit_checks(%L, 20, ''[]'')', :'co')) like '42501:%', 'or record what it found');
commit;

begin;
set local role service_role;
select t_jpa.check((select sweep and line = 20 from public.profit_alert_companies() where company_id = :'co'), 'the server sees the new line, to sweep');
select t_jpa.check((select count(*) = 1 from public.profit_alert_jobs(:'co', true) where job_id = :'job'), 'the sweep looks at the open one-off job');
select t_jpa.check(not exists (select from public.profit_alert_jobs(:'co', true) where job_id = :'weekly' and changed_at is null), 'but not the repeating one (only its change note)');
-- Found below during the sweep: listed, nobody told.
select t_jpa.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job', 'below', true, 'margin', 8.4, 'tell', false, 'title', 'Job #1 is at 8% profit, below your 20%'))) = 0, 'a job below in the sweep is told about to nobody');
select t_jpa.check(public.finish_profit_sweep(:'co', 20) = 1, 'the sweep counts the one job below');
commit;
select t_jpa.check((select count(*) = 2 from public.notifications where company_id = :'co' and kind = 'job_profit' and link = '/jobs?margin=below' and title = '1 job is below your 20% profit line'),
  'one note for each of the two people, linking to the Jobs page');
select t_jpa.check((select below and margin = 8.4 and line = 20 and told_at is null from public.job_profit_alerts where job_id = :'job'), 'the job is listed below the line, not told');

select changed_at as noted from private.job_cost_changes where job_id = :'job' \gset
begin;
set local role service_role;
select t_jpa.check((select not sweep from public.profit_alert_companies() where company_id = :'co'), 'the next check isn''t a sweep');
-- Back above the line, then below again: told this time.
select public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job', 'changed_at', :'noted', 'below', false, 'margin', 30, 'tell', false)));
commit;
select t_jpa.check(not exists (select from private.job_cost_changes where job_id = :'job'), 'the change note it read is cleared');
update public.job_line_items set unit_price = 950 where id = :'line';
begin;
set local role service_role;
select t_jpa.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job', 'changed_at', '2000-01-01T00:00:00Z', 'below', true, 'margin', 5, 'tell', true, 'title', 'Job #1 for Maria Onyx is at 5% profit, below your 20%'))) = 1,
  'gone below again, the job is told about');
commit;
select t_jpa.check(exists (select from private.job_cost_changes where job_id = :'job'), 'a change made after the one the check read is kept for the next look');
select t_jpa.check((select array_agg(user_id order by user_id) from public.notifications where kind = 'job_profit' and link = '/jobs/' || :'job') = '{c0612000-0000-0000-0000-000000000001,c0612000-0000-0000-0000-000000000002}'
  and (select bool_and(title = 'Job #1 for Maria Onyx is at 5% profit, below your 20%') from public.notifications where kind = 'job_profit' and link = '/jobs/' || :'job'),
  'the owner and Otto get it, linking to the job');
begin;
set local role service_role;
select t_jpa.check(public.record_profit_checks(:'co', 20, jsonb_build_array(jsonb_build_object('job_id', :'job', 'below', true, 'margin', 4, 'tell', true, 'title', 'again'))) = 0, 'still below, nobody is told twice');
commit;
select t_jpa.check((select count(*) = 2 from public.notifications where kind = 'job_profit' and link = '/jobs/' || :'job'), 'one notification each, still');

-- ===== Who sees it =============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select t_jpa.check(exists (select from public.job_profit_alerts where job_id = :'job'), 'Otto in the office sees where the job stands');
select t_jpa.check(t_jpa.error_of(format('update public.job_profit_alerts set below = false where job_id = %L', :'job')) like '42501:%', 'but can''t change it');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select t_jpa.check(not exists (select from public.job_profit_alerts), 'a clerk without job costs sees nothing');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000004", "role": "authenticated"}', true);
select t_jpa.check(not exists (select from public.job_profit_alerts), 'nor does the crew');
commit;

-- ===== Turned off ==============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0612000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.merge_company_settings(:'co', '{"profit_alert_percent": null}');
commit;
begin;
set local role service_role;
select t_jpa.check(not exists (select from public.profit_alert_companies() where company_id = :'co'), 'turned off, the company isn''t checked');
commit;
select t_jpa.check(not exists (select from public.job_profit_alerts where company_id = :'co') and not exists (select from private.job_cost_changes where company_id = :'co')
  and not exists (select from private.profit_alert_lines where company_id = :'co'), 'and where its jobs stood is forgotten, so turning it on again starts with a sweep');

-- A deleted job takes its standing with it, and its rows' notes don't stop the delete.
delete from public.jobs where id = :'weekly';
select t_jpa.check(not exists (select from public.jobs where id = :'weekly'), 'a job with costs on it can still be deleted');

\o
select format('All %s job-profit-alert checks passed.', last_value) from t_jpa.passed \gset
\echo :format
