-- Database tests for How you compare (20261113001420_review_comparison.sql, as
-- 20261113001700_review_comparison_place_ids_only.sql left it): the tables hold place IDs and the
-- switch and nothing Google said, because Google's terms let nothing else about a place be kept;
-- at most five competitors and one place of the business's own; the office with the marketing area
-- reads it, nobody else does, and nobody writes it from the browser; and the functions that kept
-- ratings, counts, check times and coordinates are gone.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tmkrc;
grant usage on schema tmkrc to authenticated, service_role, anon;
create function tmkrc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tmkrc.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tmkrc.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tmkrc.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
create function tmkrc.columns_of(p_table text) returns text language sql stable as $$
  select string_agg(column_name || ' ' || data_type, ', ' order by column_name)
    from information_schema.columns where table_schema = 'public' and table_name = p_table
$$;
grant execute on all functions in schema tmkrc to authenticated, service_role, anon;

\set pat 'ae100000-0000-0000-0000-000000000001'
\set olive 'ae100000-0000-0000-0000-000000000002'
\set ray 'ae100000-0000-0000-0000-000000000003'
\set dee 'ae100000-0000-0000-0000-000000000004'

begin;
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@sketchy.test', '{"full_name": "Pat Owner"}'),
  (:'olive', 'olive@sketchy.test', '{"full_name": "Olive Office"}'),
  (:'ray', 'ray@sketchy.test', '{"full_name": "Ray Crew"}'),
  (:'dee', 'dee@sketchy.test', '{"full_name": "Dee Dispatch"}');
set local role authenticated;
select tmkrc.as_user(:'pat');
select public.create_company('Sketchy Gutters', 'general') as co \gset
reset role;
select tmkrc.as_nobody();
-- Dee is in the office too, in a role without the marketing area.
insert into public.company_roles (company_id, name, base_role, permissions) values (:'co', 'Dispatch only', 'office', '{schedule}') returning id as dispatch_role \gset
insert into public.memberships (company_id, user_id, role) values (:'co', :'olive', 'office'), (:'co', :'ray', 'field_crew');
insert into public.memberships (company_id, user_id, role, role_id) values (:'co', :'dee', 'office', :'dispatch_role');
update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{marketing}', '{"enabled": true}') where id = :'co';

\o
\echo 'Only place IDs are kept'
\o /dev/null
select tmkrc.check(tmkrc.columns_of('review_comparisons') = 'company_id uuid, enabled boolean, enabled_by uuid, updated_at timestamp with time zone',
  'the switch is all a comparison keeps: no coordinates, no time of a check, no last problem (has: ' || tmkrc.columns_of('review_comparisons') || ')');
select tmkrc.check(tmkrc.columns_of('review_places') = 'company_id uuid, created_at timestamp with time zone, id uuid, is_own boolean, place_id text',
  'a place is its Google ID and whether it''s the business itself: no name, address, link, rating or count (has: ' || tmkrc.columns_of('review_places') || ')');
select tmkrc.check((select count(*) = 1 from information_schema.columns where table_schema = 'public' and table_name in ('review_comparisons', 'review_places') and data_type not in ('uuid', 'boolean', 'timestamp with time zone')),
  'place_id is the only column that could hold words or numbers');
insert into public.review_comparisons (company_id, enabled) values (:'co', true);
insert into public.review_places (company_id, place_id, is_own) values (:'co', 'ChIJj61dQgK6j4AR4GeTYWZsKWw', true);
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', 'Rival Gutters')) like '23514:%', 'a name can''t be kept where the ID goes');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', '1 Elm St, Springfield, IL')) like '23514:%', 'nor an address');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', 'https://maps.google.com/?cid=1')) like '23514:%', 'nor a Maps link');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', '4.7')) like '23514:%', 'nor a rating');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', '39.78,-89.65')) like '23514:%', 'nor coordinates');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', repeat('a', 301))) like '23514:%', 'nor anything longer than an ID');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', '')) like '23514:%', 'nor nothing');

\o
\echo 'Five competitors and the business itself'
\o /dev/null
insert into public.review_places (company_id, place_id) values (:'co', 'p1');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', 'p1')) like '23505:%', 'a place is on the card once');
insert into public.review_places (company_id, place_id) select :'co', 'p' || n from generate_series(2, 5) n;
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', 'p6')) like '22023:%', 'a sixth competitor is turned down');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id, is_own) values (%L, %L, true)', :'co', 'own2')) like '23505:%', 'and a second place of its own');
select tmkrc.check(tmkrc.error_of(format('update public.review_places set is_own = false where company_id = %L and is_own', :'co')) like '22023:%', 'the business''s own place can''t become a sixth competitor either');
delete from public.review_places where company_id = :'co' and place_id = 'p5';
insert into public.review_places (company_id, place_id) values (:'co', 'p6');
select tmkrc.check((select count(*) = 5 from public.review_places where company_id = :'co' and not is_own), 'with one removed, another fits');

\o
\echo 'Read by the office with the marketing area, written only by the server'
\o /dev/null
set local role authenticated;
select tmkrc.as_user(:'olive');
select tmkrc.check((select count(*) = 6 from public.review_places) and (select count(*) = 1 from public.review_comparisons), 'the office reads the comparison');
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', 'x')) like '42501:%', 'but can''t add a place from the browser');
select tmkrc.check(tmkrc.error_of(format('update public.review_places set place_id = %L where company_id = %L', 'y', :'co')) like '42501:%', 'nor change one');
select tmkrc.check(tmkrc.error_of(format('delete from public.review_places where company_id = %L', :'co')) like '42501:%', 'nor remove one');
select tmkrc.check(tmkrc.error_of(format('update public.review_comparisons set enabled = false where company_id = %L', :'co')) like '42501:%', 'nor flip the switch, which is an owner''s or admin''s through the server');
select tmkrc.as_user(:'pat');
select tmkrc.check((select count(*) = 6 from public.review_places), 'the owner reads it');
select tmkrc.check(tmkrc.error_of(format('update public.review_comparisons set enabled = false where company_id = %L', :'co')) like '42501:%', 'and doesn''t write it from the browser either');
select tmkrc.as_user(:'dee');
select tmkrc.check((select count(*) = 0 from public.review_places) and (select count(*) = 0 from public.review_comparisons), 'someone in the office without the marketing area doesn''t see it');
select tmkrc.as_user(:'ray');
select tmkrc.check((select count(*) = 0 from public.review_places) and (select count(*) = 0 from public.review_comparisons), 'field crew don''t see it');
reset role;
set local role anon;
select tmkrc.as_nobody();
select tmkrc.check(tmkrc.error_of('select count(*) from public.review_places') like '42501:%', 'nor anyone without signing in');
select tmkrc.check(tmkrc.error_of('select count(*) from public.review_comparisons') like '42501:%', 'the switch neither');
reset role;
select tmkrc.check((select bool_and(relrowsecurity) from pg_class where oid in ('public.review_places'::regclass, 'public.review_comparisons'::regclass)), 'row-level security is on for both tables');
select tmkrc.check((select count(*) = 1 from pg_trigger where tgrelid = 'public.review_places'::regclass and tgname = 'review_places_limit' and not tgisinternal), 'and the limit of five is still the database''s');
set local role service_role;
select tmkrc.check(tmkrc.error_of(format('insert into public.review_places (company_id, place_id) values (%L, %L)', :'co', 'p8')) like '22023:%', 'the server is held to five as well');
reset role;

\o
\echo 'Nothing is left that kept what Google said'
\o /dev/null
select tmkrc.check(to_regprocedure('public.record_review_place(uuid, text, numeric, integer, text)') is null, 'record_review_place, which kept ratings and counts, is gone');
select tmkrc.check(to_regprocedure('public.review_comparisons_due(integer)') is null, 'review_comparisons_due is gone');
select tmkrc.check(to_regprocedure('public.claim_review_comparisons(integer)') is null, 'claim_review_comparisons, the weekly check''s claim, is gone');
select tmkrc.check(to_regprocedure('public.expire_review_locations()') is null, 'expire_review_locations is gone, with the coordinates it expired');
select tmkrc.check((select count(*) = 0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and (p.proname ~ 'review_(place|comparison)' or p.proname = 'expire_review_locations')),
  'no function in the public schema works on the comparison at all');
select tmkrc.check((select string_agg(p.proname, ', ') = 'review_places_limit' from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'private' and (p.proname ~ 'review_(place|comparison)' or p.proname = 'expire_review_locations')),
  'and the only private one is the limit of five');

rollback;

\o
\echo 'All review comparison tests passed.'
