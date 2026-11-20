-- Database tests for 20261113001410_showcases.sql: the office writes a showcase that isn't
-- published, of its own job's photos only; publishing, the link's token and the photos' public
-- copies are the server's; a published one is unpublished before it changes; and anyone without
-- signing in reads one only through showcase_view, only while it's published, never the client's
-- name or address (the town only when it's chosen), and never the tables themselves.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tmksc;
grant usage on schema tmksc to authenticated, service_role, anon;
create function tmksc.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tmksc.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tmksc.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tmksc.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
grant execute on all functions in schema tmksc to authenticated, service_role, anon;

\set pat 'ad100000-0000-0000-0000-000000000001'
\set olive 'ad100000-0000-0000-0000-000000000002'
\set ray 'ad100000-0000-0000-0000-000000000003'

begin;
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@sketchy.test', '{"full_name": "Pat Owner"}'),
  (:'olive', 'olive@sketchy.test', '{"full_name": "Olive Office"}'),
  (:'ray', 'ray@sketchy.test', '{"full_name": "Ray Crew"}');
set local role authenticated;
select tmksc.as_user(:'pat');
select public.create_company('Sketchy Gutters', 'general') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'olive', 'office'), (:'co', :'ray', 'field_crew');
-- Marketing is installed: a showcase's page answers only while it is.
select tmksc.as_nobody();
update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{marketing}', '{"enabled": true}') where id = :'co';
insert into public.clients (company_id, display_name, billing_address) values (:'co', 'Ann Oak', '{"line1": "12 Oak St", "city": "Springfield", "region": "IL", "postal_code": "62701"}') returning id as client \gset
insert into public.properties (company_id, client_id, line1, city, region, postal_code) values (:'co', :'client', '12 Oak St', 'Springfield', 'IL', '62701') returning id as prop \gset
insert into public.jobs (company_id, client_id, title, property_id, status) values (:'co', :'client', 'Gutters', :'prop', 'completed') returning id as job \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Another job') returning id as other_job \gset
insert into public.visits (company_id, job_id, title, status, scheduled_on, completed_at) values (:'co', :'job', 'Gutters', 'completed', current_date, now()) returning id as visit \gset
insert into public.visits (company_id, job_id, title, status, scheduled_on) values (:'co', :'other_job', 'Another', 'scheduled', current_date) returning id as other_visit \gset
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes)
values (:'co', 'visit', :'visit', :'co' || '/visit/' || :'visit' || '/before.jpg', 'before.jpg', 'image/jpeg', 10) returning id as before_photo \gset
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes)
values (:'co', 'job', :'job', :'co' || '/job/' || :'job' || '/after.jpg', 'after.jpg', 'image/jpeg', 10) returning id as after_photo \gset
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes)
values (:'co', 'job', :'other_job', :'co' || '/job/' || :'other_job' || '/x.jpg', 'x.jpg', 'image/jpeg', 10) returning id as elsewhere \gset

\o
\echo 'The office writes a showcase of its own job''s photos'
\o /dev/null
set local role authenticated;
select tmksc.as_user(:'olive');
insert into public.showcases (company_id, job_id, visit_id, title, description, status, token, published_at)
values (:'co', :'job', :'visit', 'Gutters cleared', 'Cleared and flushed.', 'published', repeat('0', 32), now()) returning id as sc, token as tok \gset
select tmksc.check((select status = 'draft' and published_at is null and token <> repeat('0', 32) and token ~ '^[0-9a-f]{32}$' from public.showcases where id = :'sc'),
  'a new showcase is a draft with a token nobody chose');
insert into public.showcase_photos (company_id, showcase_id, attachment_id, role, public_path) values (:'co', :'sc', :'before_photo', 'before', 'anything.jpg'), (:'co', :'sc', :'after_photo', 'after', null);
select tmksc.check((select count(*) = 2 and bool_and(public_path is null) from public.showcase_photos where showcase_id = :'sc'), 'its photos are the job''s and its visit''s, with no public copy from the browser');
select tmksc.check(tmksc.error_of(format('insert into public.showcase_photos (company_id, showcase_id, attachment_id) values (%L, %L, %L)', :'co', :'sc', :'elsewhere')) like '22023:%', 'another job''s photo is turned down');
select tmksc.check(tmksc.error_of(format('update public.showcases set visit_id = %L where id = %L', :'other_visit', :'sc')) like '22023:%', 'nor a visit of another job');
update public.showcases set status = 'published', title = 'Gutters cleared and flushed' where id = :'sc';
select tmksc.check((select status = 'draft' and title = 'Gutters cleared and flushed' from public.showcases where id = :'sc'), 'the browser changes what it says, never whether it''s published');
select tmksc.check(tmksc.error_of(format('update public.showcases set job_id = %L where id = %L', :'other_job', :'sc')) = 'none' and (select job_id = :'job' from public.showcases where id = :'sc'), 'nor which job it''s of');

select tmksc.as_user(:'ray');
select tmksc.check((select count(*) = 0 from public.showcases), 'field crew don''t see showcases');
reset role;

\o
\echo 'Read publicly only while published'
\o /dev/null
set local role anon;
select tmksc.as_nobody();
select tmksc.check(tmksc.error_of(format('select public.showcase_view(%L)', :'tok')) like '42501:%', 'only the server reads a showcase for a visitor: nobody calls showcase_view from outside');
select tmksc.check(tmksc.error_of('select count(*) from public.showcases') like '42501:%', 'the table isn''t readable without signing in');
select tmksc.check(tmksc.error_of('select count(*) from public.showcase_photos') like '42501:%', 'nor its photos');
reset role;

-- The server publishes it: copies for the page, for the after photo only so far.
set local role service_role;
select tmksc.as_nobody();
update public.showcases set status = 'published', published_at = now() where id = :'sc';
update public.showcase_photos set public_path = :'co' || '/showcases/' || :'sc' || '/a.jpg' where showcase_id = :'sc' and attachment_id = :'after_photo';
reset role;
set local role service_role;
select tmksc.as_nobody();
select tmksc.check((select v ->> 'title' = 'Gutters cleared and flushed' and v -> 'town' = 'null'::jsonb and jsonb_array_length(v -> 'photos') = 1 and v -> 'photos' -> 0 ->> 'role' = 'after'
  from public.showcase_view(:'tok') v), 'published: the write-up and the photos with a copy, without the town unless chosen');
select tmksc.check((select v::text not like '%Ann Oak%' and v::text not like '%Oak St%' and v::text not like '%62701%' and v::text not like '%' || :'client' || '%' and v::text not like '%/visit/%'
  from public.showcase_view(:'tok') v), 'never the client''s name, address or ids, nor where the photos are kept');
select tmksc.check(public.showcase_view(repeat('f', 32)) is null, 'a token that isn''t one finds nothing');
reset role;

\o
\echo 'A published showcase is unpublished to change it'
\o /dev/null
set local role authenticated;
select tmksc.as_user(:'olive');
select tmksc.check(tmksc.error_of(format('update public.showcases set show_town = true where id = %L', :'sc')) like '22023:%', 'its words can''t change while it''s published');
select tmksc.check(tmksc.error_of(format('delete from public.showcase_photos where showcase_id = %L', :'sc')) like '22023:%', 'nor its photos');
reset role;
set local role service_role;
select tmksc.as_nobody();
update public.showcases set status = 'unpublished', unpublished_at = now() where id = :'sc';
update public.showcase_photos set public_path = null where showcase_id = :'sc';
reset role;
set local role authenticated;
select tmksc.as_user(:'olive');
update public.showcases set show_town = true where id = :'sc';
reset role;
set local role service_role;
select tmksc.as_nobody();
select tmksc.check(public.showcase_view(:'tok') is null, 'unpublished, the link finds nothing');
reset role;
set local role service_role;
select tmksc.as_nobody();
update public.showcases set status = 'published' where id = :'sc';
update public.showcase_photos set public_path = 'x.jpg' where showcase_id = :'sc';
reset role;
set local role service_role;
select tmksc.as_nobody();
select tmksc.check((select v ->> 'town' = 'Springfield' and v ->> 'region' = 'IL' from public.showcase_view(:'tok') v), 'published again with the town chosen: the town, never the street');
reset role;

rollback;

\o
\echo 'All showcase tests passed.'
