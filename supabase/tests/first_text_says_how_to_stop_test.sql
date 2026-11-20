-- Database tests for the numbers told how to stop texts (20261113001755_first_text_says_how_to_stop.sql):
-- the server's alone, and a number already asked for a review by text starts as told.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_ft;
grant usage on schema t_ft to authenticated, service_role;
create function t_ft.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function t_ft.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
create function t_ft.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;
grant execute on all functions in schema t_ft to authenticated, service_role;

-- Tess owns Fernhill First Lawn, Odile is in its office, Enzo estimates and Fern is field crew.
-- Nico owns another business.
insert into auth.users (id, email, raw_user_meta_data) values
  ('07e90000-0000-0000-0000-000000000001', 'tess@fernhill-first-lawn.test', '{"full_name": "Tess Tidewater"}'),
  ('07e90000-0000-0000-0000-000000000002', 'odile@fernhill-first-lawn.test', '{"full_name": "Odile Office"}'),
  ('07e90000-0000-0000-0000-000000000003', 'enzo@fernhill-first-lawn.test', '{"full_name": "Enzo Estimator"}'),
  ('07e90000-0000-0000-0000-000000000004', 'fern@fernhill-first-lawn.test', '{"full_name": "Fern Field"}'),
  ('07e90000-0000-0000-0000-000000000009', 'nico@north-first-co.test', '{"full_name": "Nico North"}');
\set tess '07e90000-0000-0000-0000-000000000001'
\set odile '07e90000-0000-0000-0000-000000000002'
\set enzo '07e90000-0000-0000-0000-000000000003'
\set fern '07e90000-0000-0000-0000-000000000004'
\set nico '07e90000-0000-0000-0000-000000000009'

begin;
set local role authenticated;
select t_ft.as_user(:'nico');
select public.create_company('North First Co', 'general') as other \gset
select t_ft.as_user(:'tess');
select public.create_company('Fernhill First Lawn', 'general') as co \gset
commit;
begin;
set local role service_role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'odile', 'office'), (:'co', :'enzo', 'estimator'), (:'co', :'fern', 'field_crew');
commit;

\o
\echo 'Numbers told how to stop'
\o /dev/null

insert into public.sms_told (company_id, phone_key) values (:'co', '5125550141');
begin;
set local role authenticated;
select t_ft.as_user(:'tess');
select t_ft.expect_error($q$select count(*) from public.sms_told$q$, 'nobody signed in reads which numbers were told how to stop');
select t_ft.expect_error(format($q$insert into public.sms_told (company_id, phone_key) values (%L, '5125550149')$q$, :'co'), 'or says one was');
commit;

\o
\echo 'The first text says how to stop: all checks passed'
