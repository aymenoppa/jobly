-- Database tests for texts turned off by the office (20261113001750_texts_off_by_the_office.sql):
-- the stop list keeps how a number came to be stopped, the record of texts going off and back on
-- is read by the office and estimators, and only the server writes either.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_to;
grant usage on schema t_to to authenticated, service_role;
create function t_to.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function t_to.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function t_to.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema t_to to authenticated, service_role;

-- Tess owns Tidewater Texts Lawn, Odile is in its office, Enzo estimates and Fern is field crew.
-- Nico owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  ('07e80000-0000-0000-0000-000000000001', 'tess@tidewater-texts.test', '{"full_name": "Tess Tidewater"}'),
  ('07e80000-0000-0000-0000-000000000002', 'odile@tidewater-texts.test', '{"full_name": "Odile Office"}'),
  ('07e80000-0000-0000-0000-000000000003', 'enzo@tidewater-texts.test', '{"full_name": "Enzo Estimator"}'),
  ('07e80000-0000-0000-0000-000000000004', 'fern@tidewater-texts.test', '{"full_name": "Fern Field"}'),
  ('07e80000-0000-0000-0000-000000000009', 'nico@north-texts.test', '{"full_name": "Nico North"}');
\set tess '07e80000-0000-0000-0000-000000000001'
\set odile '07e80000-0000-0000-0000-000000000002'
\set enzo '07e80000-0000-0000-0000-000000000003'
\set fern '07e80000-0000-0000-0000-000000000004'
\set nico '07e80000-0000-0000-0000-000000000009'

begin;
set local role authenticated;
select t_to.as_user(:'nico');
select public.create_company('North Texts Co', 'general') as other \gset
select t_to.as_user(:'tess');
select public.create_company('Tidewater Texts Lawn', 'general') as co \gset
commit;
begin;
set local role service_role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'odile', 'office'), (:'co', :'enzo', 'estimator'), (:'co', :'fern', 'field_crew');
commit;

\o
\echo 'The stop list and its record'
\o /dev/null

-- The server keeps a stop of each kind, and the record of one going on and off.
insert into public.sms_stops (company_id, phone_key, phone, source, how, note, set_by, set_by_name) values
  (:'co', '5125550141', '(512) 555-0141', 'office', 'phone', 'Called Tuesday', :'odile', 'Odile Office'),
  (:'co', '5125550142', '+15125550142', 'phrase', 'text', 'please stop texting me', null, null),
  (:'co', '5125550143', '+15125550143', 'keyword', null, null, null, null),
  (:'co', '5125550144', '+15125550144', 'carrier', null, null, null, null),
  (:'other', '5125550141', '+15125550141', 'office', 'email', null, :'nico', 'Nico North');
-- As the server before this wrote one: no source, which is a STOP.
insert into public.sms_stops (company_id, phone_key, phone) values (:'co', '5125550145', '+15125550145');
insert into public.sms_stop_changes (company_id, phone_key, phone, texts_on, source, how, note, set_by, set_by_name) values
  (:'co', '5125550141', '(512) 555-0141', false, 'office', 'phone', 'Called Tuesday', :'odile', 'Odile Office'),
  (:'co', '5125550146', '+15125550146', false, 'office', 'in_person', null, :'odile', 'Odile Office'),
  (:'co', '5125550146', '+15125550146', true, 'office', null, null, :'odile', 'Odile Office'),
  (:'other', '5125550141', '+15125550141', false, 'office', 'email', null, :'nico', 'Nico North');
select t_to.check((select source is null from public.sms_stops where company_id = :'co' and phone_key = '5125550145'), 'a stop kept the old way has no source, which reads as a STOP');
select t_to.expect_error(format($q$insert into public.sms_stops (company_id, phone_key, phone, source) values (%L, '5125550147', '+15125550147', 'guess')$q$, :'co'), 'a stop''s source is one of the four');
select t_to.expect_error(format($q$insert into public.sms_stops (company_id, phone_key, phone, source, how) values (%L, '5125550147', '+15125550147', 'office', 'fax')$q$, :'co'), 'and how they asked is one of the ways offered');
select t_to.expect_error(format($q$insert into public.sms_stop_changes (company_id, phone_key, phone, texts_on, source) values (%L, '+15125550147', '+15125550147', false, 'office')$q$, :'co'),
  'a change keeps the number by its last 10 digits');

begin;
set local role authenticated;
select t_to.as_user(:'odile');
select t_to.check((select count(*) = 5 from public.sms_stops), 'the office reads its company''s stop list');
select t_to.check((select how = 'phone' and set_by_name = 'Odile Office' and note = 'Called Tuesday' from public.sms_stops where phone_key = '5125550141'), 'with who turned texts off and how they were asked');
select t_to.check((select count(*) = 3 from public.sms_stop_changes), 'and the record of texts going off and back on');
select t_to.expect_error(format($q$insert into public.sms_stops (company_id, phone_key, phone, source) values (%L, '5125550148', '+15125550148', 'office')$q$, :'co'), 'the office doesn''t write the stop list itself: the server does, for it');
select t_to.expect_error($q$update public.sms_stops set source = 'office' where phone_key = '5125550143'$q$, 'and can''t make a STOP its own to lift');
select t_to.expect_error($q$delete from public.sms_stops where phone_key = '5125550143'$q$, 'or take one off');
select t_to.expect_error(format($q$insert into public.sms_stop_changes (company_id, phone_key, phone, texts_on, source) values (%L, '5125550148', '+15125550148', true, 'office')$q$, :'co'), 'nobody signed in adds to the record');
select t_to.expect_error($q$update public.sms_stop_changes set texts_on = true$q$, 'or changes it');
select t_to.expect_error($q$delete from public.sms_stop_changes$q$, 'or deletes from it');
select t_to.as_user(:'enzo');
select t_to.check((select count(*) = 3 from public.sms_stop_changes), 'an estimator reads the record too, as they read the stop list');
select t_to.as_user(:'fern');
select t_to.check((select count(*) = 0 from public.sms_stop_changes), 'field crew don''t');
select t_to.as_user(:'nico');
select t_to.check((select count(*) = 1 from public.sms_stop_changes), 'and another business sees only its own');
commit;

\o
\echo 'Texts off by the office: all checks passed'
