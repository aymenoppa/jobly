-- Database tests for where a number that gets texts came from (20261113001760_text_consent.sql):
-- the database notes a number someone signed in enters as the office's, which they can't make say
-- anything else; the server says where a public form's number came from; and a new contact isn't
-- ticked for texts unless whoever adds them says so.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_tc;
grant usage on schema t_tc to authenticated, service_role;
create function t_tc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function t_tc.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function t_tc.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema t_tc to authenticated, service_role;

-- Tess owns Calder Consent Lawn, Odile is in its office, Enzo estimates and Fern is field crew.
-- Nico owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  ('07ea0000-0000-0000-0000-000000000001', 'tess@calder-consent-lawn.test', '{"full_name": "Tess Tidewater"}'),
  ('07ea0000-0000-0000-0000-000000000002', 'odile@calder-consent-lawn.test', '{"full_name": "Odile Office"}'),
  ('07ea0000-0000-0000-0000-000000000003', 'enzo@calder-consent-lawn.test', '{"full_name": "Enzo Estimator"}'),
  ('07ea0000-0000-0000-0000-000000000004', 'fern@calder-consent-lawn.test', '{"full_name": "Fern Field"}'),
  ('07ea0000-0000-0000-0000-000000000009', 'nico@north-consent-co.test', '{"full_name": "Nico North"}');
\set tess '07ea0000-0000-0000-0000-000000000001'
\set odile '07ea0000-0000-0000-0000-000000000002'
\set enzo '07ea0000-0000-0000-0000-000000000003'
\set fern '07ea0000-0000-0000-0000-000000000004'
\set nico '07ea0000-0000-0000-0000-000000000009'

begin;
set local role authenticated;
select t_tc.as_user(:'nico');
select public.create_company('North Consent Co', 'general') as other \gset
select t_tc.as_user(:'tess');
select public.create_company('Calder Consent Lawn', 'general') as co \gset
commit;
begin;
set local role service_role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'odile', 'office'), (:'co', :'enzo', 'estimator'), (:'co', :'fern', 'field_crew');
commit;

\o
\echo 'Where a number came from'
\o /dev/null

begin;
set local role authenticated;
select t_tc.as_user(:'odile');
insert into public.clients (company_id, display_name, phone) values (:'co', 'Ada Added', '(512) 555-0151') returning id as ada \gset
select t_tc.check((select sms_consent_source = 'office' and sms_consent_at > now() - interval '1 minute' from public.clients where id = :'ada'), 'a client the office adds with a number has it noted as entered by the office, now');
insert into public.clients (company_id, display_name) values (:'co', 'Ned No-phone') returning id as ned \gset
select t_tc.check((select sms_consent_source is null and sms_consent_at is null from public.clients where id = :'ned'), 'one with no number has nothing noted');
insert into public.clients (company_id, display_name, phone, sms_consent_source, sms_consent_at) values (:'co', 'Cy Claimed', '512-555-0152', 'booking_form', '2020-01-01') returning id as cy \gset
select t_tc.check((select sms_consent_source = 'office' and sms_consent_at > '2026-01-01' from public.clients where id = :'cy'), 'someone signed in can''t say a number came from the booking form');
commit;

-- An earlier day, so a change shows.
update public.clients set sms_consent_at = '2026-01-05 12:00+00', sms_consent_source = 'office' where id = :'ada';
begin;
set local role authenticated;
select t_tc.as_user(:'odile');
update public.clients set notes = 'Gate on the left' where id = :'ada';
update public.clients set phone = '540.555.0151' where id = :'ada';
select t_tc.check((select sms_consent_at = '2026-01-05 12:00+00' from public.clients where id = :'ada'), 'editing something else, or writing the same number another way, leaves the record as it was');
update public.clients set sms_consent_source = 'booking_form', sms_consent_at = '2020-01-01' where id = :'ada';
select t_tc.check((select sms_consent_source = 'office' and sms_consent_at = '2026-01-05 12:00+00' from public.clients where id = :'ada'), 'and the record itself can''t be rewritten by someone signed in');
update public.clients set phone = '(512) 555-0153' where id = :'ada';
select t_tc.check((select sms_consent_source = 'office' and sms_consent_at > now() - interval '1 minute' from public.clients where id = :'ada'), 'a new number is noted afresh');
update public.clients set phone = null where id = :'ada';
select t_tc.check((select sms_consent_source is null and sms_consent_at is null from public.clients where id = :'ada'), 'and taking the number away takes the record with it');
commit;

-- The server (a booking form): it says where the number came from, after the client is made.
insert into public.clients (company_id, display_name, phone) values (:'co', 'Bea Booked', '+15125550154') returning id as bea \gset
select t_tc.check((select sms_consent_source is null from public.clients where id = :'bea'), 'a number the server adds without saying has nothing noted');
update public.clients set sms_consent_at = now(), sms_consent_source = 'booking_form' where id = :'bea';
select t_tc.check((select sms_consent_source = 'booking_form' from public.clients where id = :'bea'), 'the server notes a number given on the booking form');
update public.clients set phone = '+15125550155' where id = :'bea';
select t_tc.check((select sms_consent_source is null and sms_consent_at is null from public.clients where id = :'bea'), 'a number the server changes without saying loses the old number''s record');
select t_tc.expect_error(format($q$update public.clients set sms_consent_source = 'a guess' where id = %L$q$, :'bea'), 'where it came from is one of the places offered');

-- Contacts: a new one isn't ticked for texts unless whoever adds it says so.
insert into public.client_contacts (company_id, client_id, name, phone) values (:'co', :'ned', 'Old Otto', '512-555-0161') returning id as otto \gset
select t_tc.check((select not notify_sms and notify_email from public.client_contacts where id = :'otto'), 'a contact added without saying isn''t ticked for texts (and still is for emails)');
-- One from before this, ticked while ticks were the default, with nothing noted.
update public.client_contacts set notify_sms = true where id = :'otto';
select t_tc.check((select notify_sms and sms_consent_at is null from public.client_contacts where id = :'otto'), 'a contact ticked before this keeps the tick, with nothing noted');

begin;
set local role authenticated;
select t_tc.as_user(:'odile');
update public.client_contacts set role = 'Neighbour' where id = :'otto';
select t_tc.check((select notify_sms and sms_consent_at is null from public.client_contacts where id = :'otto'), 'and editing something else about them notes nothing');
insert into public.client_contacts (company_id, client_id, name, phone, notify_sms) values (:'co', :'ned', 'Tia Ticked', '512-555-0162', true) returning id as tia \gset
select t_tc.check((select sms_consent_source = 'office' and sms_consent_at > now() - interval '1 minute' from public.client_contacts where id = :'tia'), 'a contact the office ticks for texts has that noted, now');
insert into public.client_contacts (company_id, client_id, name, phone, notify_sms) values (:'co', :'ned', 'Uma Unticked', '512-555-0163', false) returning id as uma \gset
select t_tc.check((select sms_consent_source is null from public.client_contacts where id = :'uma'), 'one left unticked has nothing noted');
update public.client_contacts set notify_sms = true where id = :'uma';
select t_tc.check((select sms_consent_source = 'office' from public.client_contacts where id = :'uma'), 'until they''re ticked');
update public.client_contacts set notify_sms = false where id = :'uma';
select t_tc.check((select sms_consent_source is null and sms_consent_at is null from public.client_contacts where id = :'uma'), 'and unticking them clears it');
insert into public.client_contacts (company_id, client_id, name, notify_sms) values (:'co', :'ned', 'Vic No-number', true) returning id as vic \gset
select t_tc.check((select sms_consent_source is null from public.client_contacts where id = :'vic'), 'ticked with no number, there''s nothing to note');
commit;

\o
\echo 'Text consent: all checks passed'
