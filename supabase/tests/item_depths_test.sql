-- Database tests for 20261113000820_item_depths.sql: a price list item keeps a default depth, in
-- inches, within what a depth can be; the office with the price list sets it, and nobody else's
-- business can.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema t_idp;
grant usage on schema t_idp to authenticated, service_role;
create sequence t_idp.passed;
grant usage on sequence t_idp.passed to authenticated, service_role;
create function t_idp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('t_idp.passed');
  raise notice 'ok - %', p_what;
end $$;
create function t_idp.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then perform nextval('t_idp.passed'); raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema t_idp to authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('1de90000-0000-0000-0000-000000000001', 'gus@gale-paving.test', '{"full_name": "Gus Gale"}'),
  ('1de90000-0000-0000-0000-000000000009', 'hal@hart-paving.test', '{"full_name": "Hal Hart"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "1de90000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Gale Paving', 'paving') as co \gset
insert into public.services (company_id, name, unit, unit_price, formula) values (:'co', 'Gale stone base', 'ton', 46.8, 'asphalt_sqyd * depth_in * 110 / 2000') returning id as stone \gset
select t_idp.check((select default_depth_in is null from public.services where id = :'stone'), 'an item has no depth of its own until it''s given one');
update public.services set default_depth_in = 6 where id = :'stone';
select t_idp.check((select default_depth_in = 6 from public.services where id = :'stone'), 'the owner gives the stone base 6 inches');
update public.services set default_depth_in = 2.5 where id = :'stone';
select t_idp.check((select default_depth_in = 2.5 from public.services where id = :'stone'), 'a depth can be a part of an inch');
select t_idp.expect_error(format('update public.services set default_depth_in = 0 where id = %L', :'stone'), 'a depth of nothing is turned down');
select t_idp.expect_error(format('update public.services set default_depth_in = 60 where id = %L', :'stone'), 'as is one deeper than 48 inches');
update public.services set default_depth_in = null where id = :'stone';
select t_idp.check((select default_depth_in is null from public.services where id = :'stone'), 'and it can be taken off again');
update public.services set default_depth_in = 6 where id = :'stone';
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "1de90000-0000-0000-0000-000000000009", "role": "authenticated"}', true);
select public.create_company('Hart Paving', 'paving') as other \gset
update public.services set default_depth_in = 1 where id = :'stone';
commit;
select t_idp.check((select default_depth_in = 6 from public.services where id = :'stone'), 'another business can''t change it');

\o
select format('All %s item depth checks passed.', last_value) from t_idp.passed \gset
\echo :format
