-- Database tests for 20261113001210_receipt_reading.sql: receipts dropped in several at once wait as
-- drafts that nothing counts (job costs, the profit check's change notes, anything that reads
-- expenses) until the office confirms them; a draft's file is in use while it waits, goes to the
-- Trash when it's discarded and stays with the expense when it's confirmed; confirming saves the
-- expense, the materials chosen and removes the draft at once, as the person saving; and drafts are
-- the office's with job costs.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_rcr;
grant usage on schema t_rcr to authenticated, service_role;
create sequence t_rcr.passed;
grant usage on sequence t_rcr.passed to authenticated, service_role;
create function t_rcr.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('t_rcr.passed');
  raise notice 'ok - %', p_what;
end $$;
create function t_rcr.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
grant execute on all functions in schema t_rcr to authenticated, service_role;

-- Rita owns Ridge Paving; Ray is a clerk in its office without job costs; Rod is on its crew.
insert into auth.users (id, email, raw_user_meta_data) values
  ('c0613000-0000-0000-0000-000000000001', 'rita@ridge-paving.test', '{"full_name": "Rita Ridge"}'),
  ('c0613000-0000-0000-0000-000000000002', 'ray@ridge-paving.test', '{"full_name": "Ray Ridge"}'),
  ('c0613000-0000-0000-0000-000000000003', 'rod@ridge-paving.test', '{"full_name": "Rod Ridge"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Ridge Paving', 'paving') as co \gset
insert into public.company_roles (company_id, name, base_role, permissions) values (:'co', 'Ridge clerk', 'office', '{sales,invoices}') returning id as clerk \gset
insert into public.memberships (company_id, user_id, role, role_id) values (:'co', 'c0613000-0000-0000-0000-000000000002', 'office', :'clerk');
insert into public.memberships (company_id, user_id, role) values (:'co', 'c0613000-0000-0000-0000-000000000003', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Ridge Client') returning id as client \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Ridge lot') returning id as job \gset
insert into public.job_line_items (company_id, job_id, name, quantity, unit, unit_price, unit_cost) values (:'co', :'job', 'Top coat asphalt', 40, 'ton', 140, 92);
commit;

select (:'co')::text || '/receipts/' || 'r1.pdf' as path1 \gset
select (:'co')::text || '/receipts/' || 'r2.jpg' as path2 \gset

-- ===== Drafts wait, counted by nothing =========================================================
delete from private.job_cost_changes where company_id = :'co';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.expense_drafts (company_id, job_id, receipt_path, file_name) values (:'co', :'job', :'path1', 'valley-asphalt.pdf') returning id as draft1 \gset
insert into public.expense_drafts (company_id, receipt_path, file_name) values (:'co', :'path2', 'fuel.jpg') returning id as draft2 \gset
select t_rcr.check((select status = 'reading' and user_id = 'c0613000-0000-0000-0000-000000000001' from public.expense_drafts where id = :'draft1'), 'a draft starts as being read, as its uploader''s');
select t_rcr.check(t_rcr.error_of(format('insert into public.expense_drafts (company_id, receipt_path) values (%L, %L)', :'co', :'co' || '/plans/x.pdf')) like '42501:%', 'a draft''s file is in the company''s receipts folder');
update public.expense_drafts set status = 'read', read = '{"reading": {"vendor": "Valley Asphalt"}}', receipt_path = 'elsewhere' where id = :'draft1';
commit;
select t_rcr.check((select receipt_path = :'path1' and status = 'read' from public.expense_drafts where id = :'draft1'), 'what was read is kept, and its file stays the one it was');
select t_rcr.check(not exists (select from public.expenses where company_id = :'co'), 'a draft isn''t an expense: job costs, Finance and every report leave it out');
select t_rcr.check(not exists (select from private.job_cost_changes where company_id = :'co'), 'and the profit check isn''t told its job''s costs changed');
select t_rcr.check(private.stored_path_in_use(:'co', :'path1'), 'a draft''s file is in use while it waits');

-- With reading off a draft waits to be filled in (20261113001680_receipt_drafts_to_fill_in.sql).
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
insert into public.expense_drafts (company_id, receipt_path, file_name, status) values (:'co', :'co' || '/receipts/off.jpg', 'off.jpg', 'to_fill') returning id as draft_off \gset
select t_rcr.check((select status = 'to_fill' and error is null from public.expense_drafts where id = :'draft_off'), 'a receipt dropped in with reading off waits to be filled in, with nothing said to have failed');
update public.expense_drafts set status = 'waiting' where id = :'draft_off';
select t_rcr.check((select status = 'waiting' from public.expense_drafts where id = :'draft_off'), 'one past the hour''s reading allowance waits its turn (20261113001685_receipt_drafts_wait_their_turn.sql)');
select t_rcr.check(t_rcr.error_of(format('insert into public.expense_drafts (company_id, receipt_path, status) values (%L, %L, %L)', :'co', :'co' || '/receipts/odd.jpg', 'lost')) like '23514:%', 'and a draft is only ever in a state the list knows');
delete from public.expense_drafts where id = :'draft_off';
commit;

-- ===== Who has drafts ==========================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select t_rcr.check(not exists (select from public.expense_drafts), 'a clerk without job costs sees no drafts');
select t_rcr.check(t_rcr.error_of(format('insert into public.expense_drafts (company_id, receipt_path) values (%L, %L)', :'co', :'co' || '/receipts/z.jpg')) like '42501:%', 'or adds one');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000003", "role": "authenticated"}', true);
select t_rcr.check(not exists (select from public.expense_drafts), 'nor does the crew');
commit;

-- ===== Confirmed ===============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select t_rcr.check(t_rcr.error_of(format('select public.save_read_expense(%L, %L, %L)',
  jsonb_build_object('company_id', :'co', 'amount', 50, 'receipt_path', :'path2'), '[{"name": "Diesel", "unit": "gal", "quantity": 12}]', :'draft2')) like '22023:%Pick the job%',
  'materials need a job to be logged on');
select public.save_read_expense(
  jsonb_build_object('company_id', :'co', 'job_id', :'job', 'vendor', 'Valley Asphalt', 'category', 'Materials', 'amount', 4048, 'tax_amount', 0,
    'incurred_on', '2026-11-10', 'receipt_path', :'path1', 'in_line_costs', true,
    'line_items', '[{"description": "Hot-mix asphalt surface", "quantity": 44, "unit": "ton", "unit_price": 92, "amount": 4048}]'::jsonb),
  '[{"name": "Top coat asphalt", "unit": "ton", "quantity": 44, "ticket": "INV-20931"}]', :'draft1') as expense \gset
commit;
select t_rcr.check(not exists (select from public.expenses where company_id = :'co' and amount = 50), 'and nothing of it is saved');
select t_rcr.check(exists (select from public.expense_drafts where id = :'draft2'), 'its draft still waits');
select t_rcr.check((select receipt_path = :'path1' and in_line_costs and tax_amount = 0 and jsonb_array_length(line_items) = 1 and user_id = 'c0613000-0000-0000-0000-000000000001'
  from public.expenses where id = :'expense'), 'confirmed, it''s an expense with its receipt, tax and lines, as the person who confirmed it');
select t_rcr.check((select supplier = 'Valley Asphalt' and ticket = 'INV-20931' and quantity = 44 and logged_by = 'c0613000-0000-0000-0000-000000000001'
  from public.job_materials where job_id = :'job'), 'the lines chosen are logged as the job''s materials, from that supplier');
select t_rcr.check((select count(*) = 1 and bool_and(quantity = 40 and unit_price = 140) from public.job_line_items where job_id = :'job'), 'the job''s own lines aren''t touched');
select t_rcr.check(not exists (select from public.expense_drafts where id = :'draft1'), 'its draft is gone');
select t_rcr.check(not exists (select from public.trashed_files where path = :'path1'), 'and its file stays with the expense, not in the Trash');
select t_rcr.check(exists (select from private.job_cost_changes where job_id = :'job'), 'now the job''s costs have changed');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select t_rcr.check(t_rcr.error_of(format('select public.save_read_expense(%L, ''[]'', %L)', jsonb_build_object('company_id', :'co', 'amount', 1, 'receipt_path', :'path1'), :'draft1')) like 'P0002:%',
  'a draft confirmed twice is refused the second time');
commit;

-- ===== Part in the job's line items, part not (20261113001670_supplier_invoices_count_once.sql) =====
-- 44 tons the estimate covers ($4,048), logged as materials, and a $150 delivery it never had.
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.save_read_expense(
  jsonb_build_object('company_id', :'co', 'job_id', :'job', 'vendor', 'Valley Asphalt', 'category', 'Materials', 'description', 'Invoice INV-20977', 'amount', 4198, 'tax_amount', 0,
    'incurred_on', '2026-11-11', 'receipt_path', :'co' || '/receipts/split.pdf', 'invoice_number', ' INV-20977 ', 'in_line_amount', 4048, 'reimbursable', true,
    'line_items', '[{"description": "Hot-mix asphalt surface", "quantity": 44, "unit": "ton", "unit_price": 92, "amount": 4048}, {"description": "Delivery", "amount": 150}]'::jsonb),
  '[{"name": "Top coat asphalt", "unit": "ton", "quantity": 44, "ticket": "INV-20977"}]') as rest \gset
commit;
select t_rcr.check((select count(*) = 2 and sum(amount) = 4198 and bool_and(receipt_total = 4198 and invoice_number = 'INV-20977' and reimbursable and receipt_path = :'co' || '/receipts/split.pdf')
  from public.expenses where company_id = :'co' and incurred_on = '2026-11-11'),
  'an invoice that''s partly in the job''s line items is two expenses with its receipt, which come to its amount');
select t_rcr.check((select amount = 4048 and in_line_costs and description = 'Invoice INV-20977 · materials logged on the job' and jsonb_array_length(line_items) = 2
  from public.expenses where company_id = :'co' and incurred_on = '2026-11-11' and id <> :'rest'),
  'the part logged against the estimate is marked as already in the line items, so it isn''t counted again');
select t_rcr.check((select amount = 150 and not in_line_costs and description = 'Invoice INV-20977 · the rest of the invoice' from public.expenses where id = :'rest'),
  'the rest, the delivery, counts as an expense');
select t_rcr.check((select count(*) = 1 from public.job_materials where job_id = :'job' and ticket = 'INV-20977'), 'and its materials are logged once');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
-- All of it, or none of it, is one expense, as before.
select public.save_read_expense(jsonb_build_object('company_id', :'co', 'job_id', :'job', 'amount', 300, 'incurred_on', '2026-11-12', 'in_line_amount', 300)) as whole \gset
select public.save_read_expense(jsonb_build_object('company_id', :'co', 'job_id', :'job', 'amount', 80, 'incurred_on', '2026-11-12', 'in_line_amount', 0, 'in_line_costs', true)) as none \gset
select public.save_read_expense(jsonb_build_object('company_id', :'co', 'job_id', :'job', 'amount', 45, 'incurred_on', '2026-11-12', 'in_line_costs', true)) as older \gset
select t_rcr.check((select in_line_costs and receipt_total is null from public.expenses where id = :'whole') and (select not in_line_costs from public.expenses where id = :'none')
  and (select count(*) = 3 from public.expenses where company_id = :'co' and incurred_on = '2026-11-12'),
  'all of it in the line items, or none of it, is one expense: marked, or not');
select t_rcr.check((select in_line_costs from public.expenses where id = :'older'), 'and an app from before this, which sends only the tick, saves as it did');
select t_rcr.check(t_rcr.error_of(format('select public.save_read_expense(%L)', jsonb_build_object('company_id', :'co', 'job_id', :'job', 'amount', 100, 'in_line_amount', 100.01))) like '22023:%between nothing and the whole amount%'
  and t_rcr.error_of(format('select public.save_read_expense(%L)', jsonb_build_object('company_id', :'co', 'job_id', :'job', 'amount', 100, 'in_line_amount', -1))) like '22023:%between nothing and the whole amount%'
  and t_rcr.error_of(format('select public.save_read_expense(%L)', jsonb_build_object('company_id', :'co', 'amount', 100, 'in_line_amount', 40))) like '22023:%Pick the job%',
  'what''s in the line items is never more than the expense, less than nothing, or without a job');
commit;

-- ===== Discarded ===============================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "c0613000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
delete from public.expense_drafts where id = :'draft2';
commit;
select t_rcr.check((select source = 'receipt' and file_name = 'fuel.jpg' from public.trashed_files where path = :'path2'), 'a discarded draft''s file goes to the Trash');
select t_rcr.check(not private.stored_path_in_use(:'co', :'path2'), 'and isn''t in use any more');

\o
select format('All %s receipt-reading checks passed.', last_value) from t_rcr.passed \gset
\echo :format
