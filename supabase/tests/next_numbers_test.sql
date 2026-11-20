-- Database tests for 20261113000130_next_numbers.sql: owners and admins see the next request,
-- quote, job and invoice number and set it; the next document takes it; a number at or below one
-- already used is refused, saying which; nobody else sees or sets them, and the table itself stays
-- closed.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tnn;
grant usage on schema tnn to authenticated, service_role, anon;
create function tnn.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
-- The error a statement raises, as "SQLSTATE: message" ('none' when it doesn't).
create function tnn.error_of(p_sql text) returns text language plpgsql as $$
begin
  begin execute p_sql; exception when others then return sqlstate || ': ' || sqlerrm; end;
  return 'none';
end $$;
create function tnn.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- The server, or the test's own shortcuts: nobody signed in.
create function tnn.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
-- The next numbers as the caller is shown them: "request 1/0, quote 1/0, ..." (next/highest used).
create function tnn.shown(p_company uuid) returns text language sql as $$
  select string_agg(kind || ' ' || next_number || '/' || highest_used, ', ') from public.next_numbers(p_company)
$$;
grant execute on all functions in schema tnn to authenticated, service_role, anon;

\set olive '4e870000-0000-0000-0000-000000000001'
\set ada '4e870000-0000-0000-0000-000000000002'
\set opal '4e870000-0000-0000-0000-000000000003'
\set cy '4e870000-0000-0000-0000-000000000004'
\set pat '4e870000-0000-0000-0000-000000000005'

-- Everything below is rolled back at the end.
begin;
-- Olive owns Numbered Lawns; Ada is an admin; Opal is in the office; Cy is field crew. Pat owns
-- another business.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'olive', 'olive@numbered.test', '{"full_name": "Olive Owner"}'),
  (:'ada', 'ada@numbered.test', '{"full_name": "Ada Admin"}'),
  (:'opal', 'opal@numbered.test', '{"full_name": "Opal Office"}'),
  (:'cy', 'cy@numbered.test', '{"full_name": "Cy Crew"}'),
  (:'pat', 'pat@numbered.test', '{"full_name": "Pat Other"}');
set local role authenticated;
select tnn.as_user(:'pat');
select public.create_company('Numbered Paving', 'paving') as other \gset
select tnn.as_user(:'olive');
select public.create_company('Numbered Lawns', 'lawn_exterior') as co \gset
reset role;
select tnn.as_nobody();
insert into public.memberships (company_id, user_id, role) values (:'co', :'ada', 'admin'), (:'co', :'opal', 'office'), (:'co', :'cy', 'field_crew');

-- ===== Seeing them ==============================================================================
set local role authenticated;
select tnn.as_user(:'olive');
insert into public.clients (company_id, display_name) values (:'co', 'Nora Number') returning id as nora \gset
select tnn.check(tnn.shown(:'co') = 'request 1/0, quote 1/0, job 1/0, invoice 1/0', 'a new company''s next numbers are all 1, with none used');
insert into public.invoices (company_id, client_id) values (:'co', :'nora') returning number as first_invoice \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'nora', 'Mow') returning number as first_job \gset
select tnn.check(:first_invoice = 1 and :first_job = 1 and tnn.shown(:'co') = 'request 1/0, quote 1/0, job 2/1, invoice 2/1',
  'each document made moves its own next number on');

-- ===== Setting them =============================================================================
select tnn.check(public.set_next_number(:'co', 'invoice', 4311) = 4311 and tnn.shown(:'co') = 'request 1/0, quote 1/0, job 2/1, invoice 4311/1',
  'the owner carries on from another system''s invoice #4310');
insert into public.invoices (company_id, client_id) values (:'co', :'nora') returning number as moved_invoice \gset
select tnn.check(:moved_invoice = 4311 and tnn.shown(:'co') like '%invoice 4312/4311', 'the next invoice takes that number, and the one after follows it');
select tnn.check(tnn.error_of(format('select public.set_next_number(%L, %L, 4311)', :'co', 'invoice'))
    = '22023: Invoice #4311 is already used, so the next number has to be 4312 or higher. Two invoices can''t share a number.'
  and tnn.error_of(format('select public.set_next_number(%L, %L, 7)', :'co', 'invoice')) like '22023: Invoice #4311 is already used%',
  'a number at or below one already used is refused, saying which and what the lowest is');
select tnn.check(tnn.shown(:'co') like '%invoice 4312/4311', 'and nothing changes when it''s refused');
select tnn.check(public.set_next_number(:'co', 'invoice', 43120) = 43120 and public.set_next_number(:'co', 'invoice', 4312) = 4312,
  'a mistyped number comes back down, as far as the first one not used');
select tnn.as_user(:'ada');
select tnn.check(public.set_next_number(:'co', 'job', 900) = 900 and public.set_next_number(:'co', 'request', 50) = 50 and public.set_next_number(:'co', 'quote', 2000) = 2000,
  'an admin sets jobs, requests and quotes the same way');
-- A quote template takes no number, so it doesn't use the one set.
insert into public.quotes (company_id, title, is_template) values (:'co', 'Template', true);
insert into public.quotes (company_id, client_id, title) values (:'co', :'nora', 'Spring cleanup') returning number as moved_quote \gset
insert into public.requests (company_id, client_id, title) values (:'co', :'nora', 'Call back') returning number as moved_request \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'nora', 'Trim') returning number as moved_job \gset
select tnn.check(:moved_quote = 2000 and :moved_request = 50 and :moved_job = 900 and tnn.shown(:'co') = 'request 51/50, quote 2001/2000, job 901/900, invoice 4312/4311',
  'and each next document takes its number');

-- ===== What's refused ===========================================================================
select tnn.check(tnn.error_of(format('select public.set_next_number(%L, %L, 10)', :'co', 'payment')) = '22023: Numbers are set for requests, quotes, jobs and invoices'
  and tnn.error_of(format('select public.set_next_number(%L, %L, 0)', :'co', 'job')) = '22023: Enter a whole number from 1 to 999,999,999'
  and tnn.error_of(format('select public.set_next_number(%L, %L, null)', :'co', 'job')) like '22023: Enter a whole number%'
  and tnn.error_of(format('select public.set_next_number(%L, %L, 1000000000)', :'co', 'job')) like '22023: Enter a whole number%',
  'another kind of record, or a number that isn''t 1 to 999,999,999, is refused');
select tnn.as_user(:'opal');
select tnn.check(tnn.error_of(format('select public.set_next_number(%L, %L, 5000)', :'co', 'invoice')) = '42501: Only owners and admins can see and set the next numbers'
  and tnn.error_of(format('select * from public.next_numbers(%L)', :'co')) like '42501:%', 'the office can''t see or set them');
select tnn.as_user(:'cy');
select tnn.check(tnn.error_of(format('select public.set_next_number(%L, %L, 5000)', :'co', 'invoice')) like '42501:%'
  and tnn.error_of(format('select * from public.next_numbers(%L)', :'co')) like '42501:%', 'nor can crew');
select tnn.as_user(:'pat');
select tnn.check(tnn.error_of(format('select public.set_next_number(%L, %L, 5000)', :'co', 'invoice')) like '42501:%'
  and tnn.error_of(format('select * from public.next_numbers(%L)', :'co')) like '42501:%', 'nor another business''s owner');
select tnn.check(tnn.shown(:'other') = 'request 1/0, quote 1/0, job 1/0, invoice 1/0', 'whose own numbers are untouched');
select tnn.as_user(:'olive');
select tnn.check(tnn.error_of(format('update public.number_sequences set next_value = 1 where company_id = %L', :'co')) like '42501:%'
  and tnn.error_of('select 1 from public.number_sequences') like '42501:%', 'the table itself stays closed to everyone, the owner included');
set local role anon;
select tnn.check(tnn.error_of(format('select public.set_next_number(%L, %L, 5000)', :'co', 'invoice')) like '42501:%', 'and someone not signed in can''t call it at all');
reset role;
select tnn.as_nobody();
select tnn.check((select next_value from public.number_sequences where company_id = :'co' and kind = 'invoices') = 4312, 'none of that moved the invoice number');
rollback;

\echo 'All next number tests passed.'
