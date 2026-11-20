-- Database tests for unsubscribing by email address (20261113001765_unsubscribe_by_address.sql):
-- turning marketing off or back on for one client record does the same for every record of the
-- company with that address, whoever does it, and a campaign's audience leaves out an address any
-- record has opted out.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_ua;
grant usage on schema t_ua to authenticated, service_role;
create function t_ua.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function t_ua.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema t_ua to authenticated, service_role;

-- Una owns Upland Unsubscribe Lawn and Olga is in its office. Nate owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  ('07eb0000-0000-0000-0000-000000000001', 'una@upland-unsubscribe.test', '{"full_name": "Una Upland"}'),
  ('07eb0000-0000-0000-0000-000000000002', 'olga@upland-unsubscribe.test', '{"full_name": "Olga Office"}'),
  ('07eb0000-0000-0000-0000-000000000009', 'nate@north-unsubscribe.test', '{"full_name": "Nate North"}');
\set una '07eb0000-0000-0000-0000-000000000001'
\set olga '07eb0000-0000-0000-0000-000000000002'
\set nate '07eb0000-0000-0000-0000-000000000009'

begin;
set local role authenticated;
select t_ua.as_user(:'nate');
select public.create_company('North Unsubscribe Co', 'general') as other \gset
select t_ua.as_user(:'una');
select public.create_company('Upland Unsubscribe Lawn', 'general') as co \gset
commit;
begin;
set local role service_role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'olga', 'office');
commit;

-- Ana has two records under one address (her home, and a rental kept apart), written differently.
-- Bo has his own. Cy has no email. Another business has an Ana of its own.
insert into public.clients (company_id, display_name, email) values (:'co', 'Ana Smith', 'ana@example.com') returning id as ana \gset
insert into public.clients (company_id, display_name, email) values (:'co', 'Ana Smith (rental)', '  ANA@Example.com ') returning id as rental \gset
insert into public.clients (company_id, display_name, email) values (:'co', 'Bo Lee', 'bo@example.com') returning id as bo \gset
insert into public.clients (company_id, display_name) values (:'co', 'Cy No-email') returning id as cy \gset
insert into public.clients (company_id, display_name) values (:'co', 'Di No-email') returning id as di \gset
insert into public.clients (company_id, display_name, email) values (:'other', 'Ana Elsewhere', 'ana@example.com') returning id as elsewhere \gset

\o
\echo 'One unsubscribe, every record with the address'
\o /dev/null

-- The unsubscribe link (the server) turns marketing off on the record the email was sent for.
update public.clients set marketing_opt_out = true where id = :'ana';
select t_ua.check((select marketing_opt_out from public.clients where id = :'rental'), 'unsubscribing one record unsubscribes the other record with that address, however it''s written');
select t_ua.check((select not marketing_opt_out from public.clients where id = :'bo'), 'a client with another address isn''t touched');
select t_ua.check((select not marketing_opt_out from public.clients where id = :'elsewhere'), 'nor is another business''s client with the same address');

-- Resubscribing from the page does the same the other way.
update public.clients set marketing_opt_out = false where id = :'rental';
select t_ua.check((select not marketing_opt_out from public.clients where id = :'ana'), 'resubscribing one record resubscribes the other');

-- The office's switch on a client's page.
begin;
set local role authenticated;
select t_ua.as_user(:'olga');
update public.clients set marketing_opt_out = true where id = :'rental';
select t_ua.check((select marketing_opt_out from public.clients where id = :'ana'), 'the office turning Marketing off on one record turns it off on the other');
commit;

-- No address, nothing to follow.
update public.clients set marketing_opt_out = true where id = :'cy';
select t_ua.check((select not marketing_opt_out from public.clients where id = :'di'), 'a client with no email address opting out changes nobody else');
select t_ua.check((select count(*) = 3 from public.clients where company_id = :'co' and marketing_opt_out), 'only Ana''s two records and Cy are out');

\o
\echo 'Audiences'
\o /dev/null

-- A third record for Ana, added after she unsubscribed, and a second for Bo.
insert into public.clients (company_id, display_name, email) values (:'co', 'Ana Smith (new)', 'Ana@example.com') returning id as newer \gset
insert into public.clients (company_id, display_name, email) values (:'co', 'Bo Lee (shop)', 'BO@example.com');
select t_ua.check((select not marketing_opt_out from public.clients where id = :'newer'), 'a record added later with that address isn''t marked by being added');

begin;
set local role authenticated;
select t_ua.as_user(:'olga');
select t_ua.check((select count(*) = 0 from public.campaign_audience(:'co', '{}') where email = 'ana@example.com'),
  'a campaign''s audience leaves out an address any record has opted out, the record added later included');
select t_ua.check((select count(*) = 1 from public.campaign_audience(:'co', '{}') where email = 'bo@example.com'), 'and still takes an address once however many records have it');
select t_ua.check((select count(*) = 1 from public.campaign_audience(:'co', '{}')), 'so only Bo gets it');
commit;

-- She resubscribes: every record is back in, once.
update public.clients set marketing_opt_out = false where id = :'ana';
begin;
set local role authenticated;
select t_ua.as_user(:'olga');
select t_ua.check((select count(*) = 1 from public.campaign_audience(:'co', '{}') where email = 'ana@example.com'), 'resubscribed, the address is in the audience again, once');
commit;

\o
\echo 'Unsubscribe by address: all checks passed'
