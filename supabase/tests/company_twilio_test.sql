-- Database tests for texting from a company's own Twilio account
-- (20261113000320_company_twilio.sql): a sub with only a phone is promised a link to send in new
-- paperwork when their company has connected its own account, not only when the server has one;
-- and a company's Twilio account is kept like its other apps (only owners and admins see that it's
-- connected, and nobody signed in reads its Auth Token).
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_tw;
grant usage on schema t_tw to authenticated, service_role;
create function t_tw.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function t_tw.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema t_tw to authenticated, service_role;

-- Tess owns Tamarack Texting Roofing and Oren is in its office.
insert into auth.users (id, email, raw_user_meta_data) values
  ('7e570000-0000-0000-0000-000000000001', 'tess@tamarack-texting.test', '{"full_name": "Tess Tamarack"}'),
  ('7e570000-0000-0000-0000-000000000002', 'oren@tamarack-texting.test', '{"full_name": "Oren Office"}');
\set tess '7e570000-0000-0000-0000-000000000001'
\set oren '7e570000-0000-0000-0000-000000000002'

begin;
set local role authenticated;
select t_tw.as_user(:'tess');
select public.create_company('Tamarack Texting Roofing', 'general') as co \gset
commit;
begin;
set local role service_role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'oren', 'office');
commit;
-- A time zone where it's daytime now: reminders go out from 8 in the morning.
update public.companies set timezone = (select name from pg_timezone_names where name ~ '^Etc/GMT[+-][0-9]+$' and extract(hour from now() at time zone name) between 9 and 20 order by name limit 1)
 where id = :'co';

-- Hauling has only a phone on file, Insulation only an email. Both certificates run out in 20 days.
insert into public.subcontractors (company_id, name, phone) values (:'co', 'Tango Hauling', '+15125550177') returning id as hauling \gset
insert into public.subcontractors (company_id, name, email) values (:'co', 'Tango Insulation', 'ti@insulation.test') returning id as insulation \gset
set role service_role;
insert into public.sub_documents (company_id, subcontractor_id, kind, path, expires_on) values
  (:'co', :'hauling', 'liability', :'co' || '/subs/' || :'hauling' || '/gl.pdf', private.company_today(:'co') + 20),
  (:'co', :'insulation', 'liability', :'co' || '/subs/' || :'insulation' || '/gl.pdf', private.company_today(:'co') + 20);
select t_tw.check((select count(*) = 2 and bool_and(not remind_sub) from public.emit_sub_document_alerts() where company_id = :'co'),
  'with no Twilio account on the server or the company, a sub with only a phone isn''t promised a link');
reset role;

-- A key saved for Twilio before accounts could be connected (no Account SID) never sent anything.
update public.sub_documents set expires_on = private.company_today(:'co') + 6 where company_id = :'co';
insert into public.integrations (company_id, provider, status, account_label) values (:'co', 'twilio', 'connected', 'Key ending 1234');
set role service_role;
select t_tw.check((select count(*) = 2 and bool_and(not remind_sub) from public.emit_sub_document_alerts() where company_id = :'co'),
  'a key saved the old way, with no account behind it, doesn''t count');
reset role;

-- The company connects its own account on the Apps page (the server writes it).
update public.sub_documents set expires_on = private.company_today(:'co') where company_id = :'co';
update public.integrations set external_account_id = 'AC' || repeat('a', 32), settings = '{"from_number": "+15125550100", "phone_sid": "PN123"}', account_label = 'Tamarack · (512) 555-0100'
 where company_id = :'co' and provider = 'twilio';
insert into public.integration_secrets (company_id, provider, ciphertext) values (:'co', 'twilio', 'v1.sealed');
set role service_role;
select t_tw.check((select array_agg(subcontractor_id::text || ':' || remind_sub order by subcontractor_id) from public.emit_sub_document_alerts() where company_id = :'co')
  = (select array_agg(id::text || ':' || (id = :'hauling') order by id) from public.subcontractors where id in (:'hauling', :'insulation')),
  'the company''s own Twilio account reaches a sub with a phone, and still not one with only an email');
reset role;
select t_tw.check((select count(*) >= 1 from public.notifications where company_id = :'co' and title like 'Tango Hauling%' and body like '%sending them a link%')
  and (select count(*) = 0 from public.notifications where company_id = :'co' and title like 'Tango Insulation%' and body like '%sending them a link%'),
  'and the office is told a link is on its way to the one, and not to the other');

-- Disconnected, it stops counting.
update public.sub_documents set alerted_state = null where company_id = :'co';
update public.integrations set status = 'disconnected' where company_id = :'co' and provider = 'twilio';
set role service_role;
select t_tw.check((select count(*) = 2 and bool_and(not remind_sub) from public.emit_sub_document_alerts() where company_id = :'co'), 'a disconnected account doesn''t count');
reset role;
update public.integrations set status = 'connected' where company_id = :'co' and provider = 'twilio';

-- Who sees the account.
begin;
set local role authenticated;
select t_tw.as_user(:'tess');
select t_tw.check((select count(*) = 1 and bool_and(external_account_id like 'AC%' and settings ->> 'from_number' = '+15125550100') from public.integrations where provider = 'twilio'),
  'the owner sees the account and its number');
select t_tw.check(not has_table_privilege('authenticated', 'public.integration_secrets', 'select'), 'nobody signed in reads its Auth Token');
select t_tw.as_user(:'oren');
select t_tw.check((select count(*) = 0 from public.integrations where provider = 'twilio'), 'the office doesn''t see the app''s connection');
rollback;

-- Left as it was found, for the tests after this one.
delete from public.companies where id = :'co';
set client_min_messages = warning;
drop schema t_tw cascade;
reset client_min_messages;

\o
\echo 'All company Twilio tests passed.'
