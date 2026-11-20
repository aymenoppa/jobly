-- Database tests for 20261113000101_finished_jobs_ask_for_their_invoice.sql: a one-off job whose
-- last visit is finished (or whose last open visit is cancelled or deleted after another was
-- finished) is marked Requires invoicing as the Mark work complete button does, with one
-- notification for the people who look after money; a job already invoiced is closed instead; a
-- job whose card that would charge is left alone and the office told; the company's switch; a visit
-- added afterwards making the job active again; and what's left alone (recurring jobs, a job a
-- person marked, the column that records it).
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tfj;
grant usage on schema tfj to authenticated, service_role;
create function tfj.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tfj.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- A one-off job for a client with one $300 line, as the server would make it.
create function tfj.job(p_company uuid, p_client uuid, p_title text, p_billing text default 'on_completion') returns uuid language plpgsql as $$
declare v_job uuid;
begin
  insert into public.jobs (company_id, client_id, title, billing_mode) values (p_company, p_client, p_title, p_billing) returning id into v_job;
  insert into public.job_line_items (company_id, job_id, name, unit_price) values (p_company, v_job, 'Work', 300);
  return v_job;
end $$;
-- A visit on it today, with Cy (field crew) on it.
create function tfj.visit(p_company uuid, p_job uuid, p_title text default 'Visit', p_status text default 'scheduled') returns uuid language plpgsql as $$
declare v_visit uuid;
begin
  insert into public.visits (company_id, job_id, title, status, scheduled_on) values (p_company, p_job, p_title, p_status, private.company_today(p_company))
  returning id into v_visit;
  insert into public.visit_assignees (company_id, visit_id, user_id) values (p_company, v_visit, 'f1a50000-0000-0000-0000-000000000003');
  return v_visit;
end $$;
-- A job as "status, marked by the database or not".
create function tfj.state(p_job uuid) returns text language sql as $$
  select status || case when finished_by_visits_at is not null then ', by its visits' else '' end from public.jobs where id = p_job
$$;
-- The notifications about a job for someone, as "title | body" lines.
create function tfj.told(p_user uuid, p_job uuid) returns text language sql as $$
  select string_agg(title || ' | ' || coalesce(body, ''), E'\n' order by created_at, title)
  from public.notifications where user_id = p_user and kind = 'job' and link = '/jobs/' || p_job
$$;
create function tfj.told_count(p_job uuid) returns bigint language sql as $$
  select count(*) from public.notifications where kind = 'job' and link = '/jobs/' || p_job
$$;
-- The server, or the test's own shortcuts: nobody signed in.
create function tfj.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
grant execute on all functions in schema tfj to authenticated, service_role;

\set olive 'f1a50000-0000-0000-0000-000000000001'
\set opal 'f1a50000-0000-0000-0000-000000000002'
\set cy 'f1a50000-0000-0000-0000-000000000003'
\set otto 'f1a50000-0000-0000-0000-000000000004'

-- Everything below is rolled back at the end.
begin;
-- Olive owns Finish Line Fencing; Opal is in the office; Otto is in the office as an operations
-- manager (no invoices area); Cy is field crew.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'olive', 'olive@finish.test', '{"full_name": "Olive Owner"}'),
  (:'opal', 'opal@finish.test', '{"full_name": "Opal Office"}'),
  (:'cy', 'cy@finish.test', '{"full_name": "Cy Crew"}'),
  (:'otto', 'otto@finish.test', '{"full_name": "Otto Ops"}');
set local role authenticated;
select tfj.as_user(:'olive');
select public.create_company('Finish Line Fencing', 'general') as co \gset
select id as ops_role from public.company_roles where company_id = :'co' and name = 'Operations manager' \gset
reset role;
select tfj.as_nobody();
insert into public.memberships (company_id, user_id, role, role_id) values
  (:'co', :'opal', 'office', null), (:'co', :'cy', 'field_crew', null), (:'co', :'otto', 'office', :'ops_role');
insert into public.clients (company_id, display_name) values (:'co', 'Maria Lopez') returning id as maria \gset

-- ===== The last visit finished ==================================================================
select tfj.job(:'co', :'maria', 'Back fence') as j1 \gset
select tfj.visit(:'co', :'j1', 'Day 1') as j1a \gset
select tfj.visit(:'co', :'j1', 'Day 2') as j1b \gset
select number as j1_number from public.jobs where id = :'j1' \gset

set local role authenticated;
select tfj.as_user(:'cy');
update public.visits set status = 'completed' where id = :'j1a';
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j1') = 'active' and tfj.told_count(:'j1') = 0, 'a job with a visit still to do stays as it is, and nobody is told');

set local role authenticated;
select tfj.as_user(:'cy');
update public.visits set status = 'in_progress' where id = :'j1b';
-- Tapped two days ago, synced now: it counts when it reaches the database.
update public.visits set status = 'completed', completed_at = now() - interval '2 days' where id = :'j1b';
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j1') = 'requires_invoicing, by its visits', 'a crew finishing the last visit marks the work complete, though crews can''t change jobs');
select tfj.check((select count(*) from public.activity where subject_id = :'j1' and verb = 'job.completed') = 1, 'with the same job.completed event the button raises, once');
select tfj.check(tfj.told(:'olive', :'j1') = format('Job #%s for Maria Lopez is finished and ready to invoice | Its last visit was finished, so the work was marked complete.', :'j1_number')
  and tfj.told(:'opal', :'j1') = tfj.told(:'olive', :'j1'), 'the owner and the office are told, once each, with the job''s number and client');
select tfj.check(tfj.told(:'otto', :'j1') is null and tfj.told(:'cy', :'j1') is null and tfj.told_count(:'j1') = 2,
  'and nobody without the invoices area');

set local role authenticated;
select tfj.as_user(:'opal');
select tfj.check((select public.job_state(j) from public.jobs j where j.id = :'j1') = 'requires_invoicing', 'the Jobs list reads it as Requires invoicing');
select tfj.check((public.dashboard(:'co') -> 'workflow' -> 'jobs' ->> 'to_invoice')::integer = 1, 'Home counts it');
select tfj.check((select count(*) from public.jobs where company_id = :'co' and status = 'requires_invoicing') = 1, 'and Invoices lists it as ready to invoice');
select public.create_invoice_for_job(:'j1', 'standard') as j1_invoice \gset
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j1') = 'completed, by its visits', 'its invoice closes it, as ever');

-- ===== Several at once, cancelled and deleted visits ============================================
select tfj.job(:'co', :'maria', 'Two at once') as j2 \gset
select tfj.visit(:'co', :'j2') as j2a \gset
select tfj.visit(:'co', :'j2') as j2b \gset
update public.visits set status = 'completed' where job_id = :'j2';
select tfj.check(tfj.state(:'j2') = 'requires_invoicing, by its visits' and tfj.told_count(:'j2') = 2
  and (select count(*) from public.activity where subject_id = :'j2' and verb = 'job.completed') = 1,
  'two visits finished in one go mark the job once: one notification a person, not one a visit');

select tfj.job(:'co', :'maria', 'Second day called off') as j3 \gset
select tfj.visit(:'co', :'j3') as j3a \gset
select tfj.visit(:'co', :'j3') as j3b \gset
update public.visits set status = 'completed' where id = :'j3a';
update public.visits set status = 'cancelled' where id = :'j3b';
select tfj.check(tfj.state(:'j3') = 'requires_invoicing, by its visits', 'cancelling the last open visit after another was finished marks it');

select tfj.job(:'co', :'maria', 'Second day deleted') as j4 \gset
select tfj.visit(:'co', :'j4') as j4a \gset
select tfj.visit(:'co', :'j4') as j4b \gset
update public.visits set status = 'completed' where id = :'j4a';
delete from public.visits where id = :'j4b';
select tfj.check(tfj.state(:'j4') = 'requires_invoicing, by its visits', 'and so does deleting it');

select tfj.job(:'co', :'maria', 'Never done') as j5 \gset
select tfj.visit(:'co', :'j5') as j5a \gset
select tfj.visit(:'co', :'j5') as j5b \gset
update public.visits set status = 'cancelled' where id = :'j5a';
delete from public.visits where id = :'j5b';
select tfj.check(tfj.state(:'j5') = 'active' and tfj.told_count(:'j5') = 0, 'a job none of whose visits was finished stays as it is');

-- A task or an assessment on the job isn't its work.
select tfj.job(:'co', :'maria', 'Task still open') as j6 \gset
select tfj.visit(:'co', :'j6') as j6a \gset
insert into public.visits (company_id, job_id, title, kind, scheduled_on) values (:'co', :'j6', 'Order parts', 'task', current_date);
update public.visits set status = 'completed' where id = :'j6a';
select tfj.check(tfj.state(:'j6') = 'requires_invoicing, by its visits', 'only job visits count: an open task doesn''t hold the job back');

-- A visit logged as already completed counts when a person logs it, not when the server loads it.
select tfj.job(:'co', :'maria', 'Logged afterwards') as j15 \gset
select tfj.visit(:'co', :'j15', 'Loaded by the server', 'completed') as j15a \gset
select tfj.check(tfj.state(:'j15') = 'active' and tfj.told_count(:'j15') = 0, 'a finished visit the server or an import adds, with nobody signed in, marks nothing');
set local role authenticated;
select tfj.as_user(:'opal');
insert into public.visits (company_id, job_id, title, status, scheduled_on) values (:'co', :'j15', 'Done yesterday', 'completed', current_date - 1);
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j15') = 'requires_invoicing, by its visits', 'a visit the office logs as already completed marks the job');

-- ===== A visit added or reopened afterwards =====================================================
select tfj.visit(:'co', :'j2', 'Touch-up') as j2c \gset
select tfj.check(tfj.state(:'j2') = 'active', 'a visit added to a job the database marked makes it active again');
update public.visits set status = 'completed' where id = :'j2c';
select tfj.check(tfj.state(:'j2') = 'requires_invoicing, by its visits' and tfj.told_count(:'j2') = 4, 'and finishing it marks the job again, and says so again');
set local role authenticated;
select tfj.as_user(:'opal');
update public.visits set status = 'scheduled' where id = :'j2c';
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j2') = 'active', 'reopening its visit does the same');
set local role authenticated;
select tfj.as_user(:'opal');
update public.jobs set status = 'requires_invoicing' where id = :'j2';
update public.jobs set finished_by_visits_at = now() where id = :'j2';
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j2') = 'requires_invoicing', 'a job a person marked isn''t recorded as marked by its visits, and nobody can write that by hand');
select tfj.visit(:'co', :'j2', 'Another') as j2d \gset
select tfj.check(tfj.state(:'j2') = 'requires_invoicing', 'and a visit added to it leaves it as the person left it');
select tfj.visit(:'co', :'j1', 'Warranty call') as j1c \gset
select tfj.check(tfj.state(:'j1') = 'completed, by its visits', 'a job already invoiced and closed stays closed when a visit is added');

-- ===== Already invoiced =========================================================================
select tfj.job(:'co', :'maria', 'Invoiced up front') as j7 \gset
select tfj.visit(:'co', :'j7') as j7a \gset
set local role authenticated;
select tfj.as_user(:'opal');
select public.create_invoice_for_job(:'j7', 'standard') as j7_invoice \gset
select tfj.as_user(:'cy');
update public.visits set status = 'completed' where id = :'j7a';
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j7') = 'completed, by its visits' and tfj.told_count(:'j7') = 0,
  'a job that already has its final invoice is closed, not asked for another, and nobody is told to invoice it');

select tfj.job(:'co', :'maria', 'Billed in parts', 'progress') as j8 \gset
select tfj.visit(:'co', :'j8') as j8a \gset
set local role authenticated;
select tfj.as_user(:'opal');
select public.create_invoice_for_job(:'j8', 'progress', 100) as j8_invoice \gset
reset role;
select tfj.as_nobody();
update public.visits set status = 'completed' where id = :'j8a';
select tfj.check(tfj.state(:'j8') = 'requires_invoicing, by its visits', 'a progress-billed job still has its final invoice to make');

-- A one-off job billed per visit: what's left is its finished visits not on an invoice.
select tfj.job(:'co', :'maria', 'Per visit', 'per_visit') as j9 \gset
select tfj.visit(:'co', :'j9') as j9a \gset
select tfj.visit(:'co', :'j9') as j9b \gset
update public.visits set status = 'completed' where id = :'j9a';
set local role authenticated;
select tfj.as_user(:'opal');
select public.create_invoice_for_job(:'j9', 'visits') as j9_invoice \gset
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j9') = 'active', 'a per-visit job with a visit to go stays active when the finished one is invoiced');
update public.visits set status = 'completed' where id = :'j9b';
select tfj.check(tfj.state(:'j9') = 'requires_invoicing, by its visits', 'its last visit finished leaves that visit to invoice');
select tfj.job(:'co', :'maria', 'Per visit, rest called off', 'per_visit') as j10 \gset
select tfj.visit(:'co', :'j10') as j10a \gset
select tfj.visit(:'co', :'j10') as j10b \gset
update public.visits set status = 'completed' where id = :'j10a';
set local role authenticated;
select tfj.as_user(:'opal');
select public.create_invoice_for_job(:'j10', 'visits') as j10_invoice \gset
reset role;
select tfj.as_nobody();
update public.visits set status = 'cancelled' where id = :'j10b';
select tfj.check(tfj.state(:'j10') = 'completed, by its visits', 'and with every finished visit invoiced, cancelling the rest closes it');

-- ===== Recurring jobs ===========================================================================
insert into public.jobs (company_id, client_id, title, kind, recurrence_rule, starts_on) values (:'co', :'maria', 'Weekly mow', 'recurring', 'FREQ=WEEKLY;INTERVAL=1', current_date)
  returning id as jr \gset
select tfj.visit(:'co', :'jr') as jra \gset
update public.visits set status = 'completed' where id = :'jra';
select tfj.check(tfj.state(:'jr') = 'active' and tfj.told_count(:'jr') = 0, 'a recurring job is left to its own billing');

-- ===== Autopay ==================================================================================
-- The Apps page saved what the company's key can do, Olive turned autopay on, and Andy agreed to it.
insert into public.integrations (company_id, provider, status, settings) values (:'co', 'stripe', 'connected', '{"autopay": true, "refunds": true}');
set local role authenticated;
select tfj.as_user(:'olive');
select public.autopay_set_settings(:'co', jsonb_build_object('enabled', true, 'terms', 'We charge the card on file when the work is done.', 'timing', 'end_of_day', 'days', null,
  'max_amount', 500, 'receipts', true, 'jobs_default', false, 'card_required', false)) as saved \gset
reset role;
select tfj.as_nobody();
insert into public.clients (company_id, display_name) values (:'co', 'Andy Autopay') returning id as andy \gset
select public.autopay_save_payment_method(:'co', :'andy', jsonb_build_object(
  'stripe_payment_method_id', 'pm_finish_andy', 'stripe_customer_id', 'cus_finish_andy', 'stripe_account', 'acct_finish', 'livemode', false,
  'type', 'card', 'brand', 'visa', 'last4', '4242', 'exp_month', 8, 'exp_year', 2030, 'status', 'active', 'source', 'hub', 'make_default', true)) as andy_pm \gset
select public.autopay_record_authorization(:'co', :'andy', :'andy_pm', 'hub', private.autopay_terms_version(:'co'), '203.0.113.7', 'Test browser', 'client', 'client') as andy_agreed \gset

select tfj.job(:'co', :'andy', 'Gate on autopay') as j11 \gset
select tfj.visit(:'co', :'j11') as j11a \gset
select number as j11_number from public.jobs where id = :'j11' \gset
set local role authenticated;
select tfj.as_user(:'opal');
update public.jobs set autopay = true where id = :'j11';
select tfj.as_user(:'cy');
update public.visits set status = 'completed' where id = :'j11a';
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j11') = 'active' and not exists (select 1 from public.autopay_charges where job_id = :'j11'),
  'a crew finishing the last visit of a job on autopay doesn''t mark it, so no card is charged');
select tfj.check(tfj.told(:'opal', :'j11') = format('Job #%s for Andy Autopay is finished. Mark work complete to charge their card | It''s on autopay, so it wasn''t marked complete for you. Pressing Mark work complete on the job charges Visa ending 4242.', :'j11_number')
  and tfj.told_count(:'j11') = 2, 'the office is told instead, and that marking it complete charges the card');
set local role authenticated;
select tfj.as_user(:'opal');
update public.jobs set status = 'requires_invoicing' where id = :'j11';
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j11') = 'requires_invoicing' and (select count(*) from public.autopay_charges where job_id = :'j11' and status = 'waiting') = 1,
  'the office marking it complete queues the charge, as before');

select tfj.job(:'co', :'andy', 'Gate not on autopay') as j12 \gset
select tfj.visit(:'co', :'j12') as j12a \gset
update public.visits set status = 'completed' where id = :'j12a';
select tfj.check(tfj.state(:'j12') = 'requires_invoicing, by its visits' and not exists (select 1 from public.autopay_charges where job_id = :'j12'),
  'the same client''s job that isn''t on autopay is marked as any other');

-- ===== The switch ===============================================================================
select tfj.check(private.completes_finished_jobs(:'co'), 'the switch is on until someone turns it off');
set local role authenticated;
select tfj.as_user(:'olive');
select public.merge_company_settings(:'co', '{"jobs": {"complete_when_visits_done": false}}');
reset role;
select tfj.as_nobody();
select tfj.job(:'co', :'maria', 'Switch off') as j13 \gset
select tfj.visit(:'co', :'j13') as j13a \gset
select number as j13_number from public.jobs where id = :'j13' \gset
select tfj.job(:'co', :'maria', 'Switch off, invoiced') as j14 \gset
select tfj.visit(:'co', :'j14') as j14a \gset
set local role authenticated;
select tfj.as_user(:'opal');
select public.create_invoice_for_job(:'j14', 'standard') as j14_invoice \gset
select tfj.as_user(:'cy');
update public.visits set status = 'completed' where id in (:'j13a', :'j14a');
reset role;
select tfj.as_nobody();
select tfj.check(tfj.state(:'j13') = 'active' and (select public.job_state(j) from public.jobs j where j.id = :'j13') = 'unscheduled',
  'with the switch off the job stays as it was');
select tfj.check(tfj.told(:'opal', :'j13') = format('Job #%s for Maria Lopez has had its last visit finished | Press Mark work complete on the job when it''s ready to invoice.', :'j13_number')
  and tfj.told_count(:'j13') = 2, 'and the office is still told');
select tfj.check(tfj.state(:'j14') = 'active' and tfj.told_count(:'j14') = 0, 'a job already invoiced is left alone too, with nothing to tell');
rollback;

\echo 'All finished job tests passed.'
