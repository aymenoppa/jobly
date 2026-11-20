-- Database tests for each person's language (20261113001300_profile_language.sql): nobody has one
-- until they choose, each person can set only their own to English or Spanish, and the owner can
-- read the team's (the team list shows it).
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tplg;
grant usage on schema tplg to authenticated, service_role;
create table tplg.passed (n integer not null default 0);
insert into tplg.passed values (0);
grant select, update on tplg.passed to authenticated;
create function tplg.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  update tplg.passed set n = n + 1;
  raise notice 'ok - %', p_what;
end $$;
create function tplg.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    update tplg.passed set n = n + 1;
    raise notice 'ok - % (%)', p_what, sqlerrm;
    return;
  end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema tplg to authenticated, service_role;

-- Olga owns Ortiz Landscaping; Rosa is on her field crew.
insert into auth.users (id, email, raw_user_meta_data) values
  ('7f1a0000-0000-0000-0000-000000000001', 'olga@ortiz.test', '{"full_name": "Olga Ortiz"}'),
  ('7f1a0000-0000-0000-0000-000000000002', 'rosa@ortiz.test', '{"full_name": "Rosa Ruiz"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "7f1a0000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select public.create_company('Ortiz Landscaping', 'lawn') as co \gset
insert into public.memberships (company_id, user_id, role) values (:'co', '7f1a0000-0000-0000-0000-000000000002', 'field_crew');
commit;

\echo 'Each person''s language'
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "7f1a0000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select tplg.check((select locale is null from public.profiles where user_id = '7f1a0000-0000-0000-0000-000000000002'), 'nobody has a language until they choose one');
update public.profiles set locale = 'es' where user_id = '7f1a0000-0000-0000-0000-000000000002';
select tplg.check((select locale = 'es' from public.profiles where user_id = '7f1a0000-0000-0000-0000-000000000002'), 'a crew member can choose Spanish for themselves');
update public.profiles set locale = 'es' where user_id = '7f1a0000-0000-0000-0000-000000000001';
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "7f1a0000-0000-0000-0000-000000000002", "role": "authenticated"}', true);
select tplg.expect_error($q$update public.profiles set locale = 'fr' where user_id = '7f1a0000-0000-0000-0000-000000000002'$q$, 'a language Jobly doesn''t speak is refused');
select tplg.expect_error($q$update public.profiles set locale = 'ES' where user_id = '7f1a0000-0000-0000-0000-000000000002'$q$, 'only the lower-case code is taken');
update public.profiles set locale = null where user_id = '7f1a0000-0000-0000-0000-000000000002';
select tplg.check((select locale is null from public.profiles where user_id = '7f1a0000-0000-0000-0000-000000000002'), 'and they can go back to following their device');
update public.profiles set locale = 'es' where user_id = '7f1a0000-0000-0000-0000-000000000002';
commit;

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "7f1a0000-0000-0000-0000-000000000001", "role": "authenticated"}', true);
select tplg.check((select locale is null from public.profiles where user_id = '7f1a0000-0000-0000-0000-000000000001'), 'nobody can choose a language for someone else');
select tplg.check((select locale = 'es' from public.profiles where user_id = '7f1a0000-0000-0000-0000-000000000002'), 'the owner reads each person''s language');
-- Not even the owner, for someone on their team: each person chooses their own.
update public.profiles set locale = 'en' where user_id = '7f1a0000-0000-0000-0000-000000000002';
select tplg.check((select locale = 'es' from public.profiles where user_id = '7f1a0000-0000-0000-0000-000000000002'), 'the owner can''t change a crew member''s language');
commit;

do $$ begin raise notice 'All % language checks passed.', (select n from tplg.passed); end $$;
