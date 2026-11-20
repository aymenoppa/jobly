-- Database tests for 20261113001580_showcases_come_down.sql: a published showcase comes down by
-- itself when the client says not to post photos of their property (or its job moves to a client
-- who has), or when one of its photos is no longer OK to share, and the office is told why; its
-- page answers nothing while Marketing is uninstalled; only the server reads it for a visitor; the
-- public copies of a showcase that's taken down or deleted are queued for deletion; and deleting a
-- photo that's on a published showcase says what to do.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tmksf;
grant usage on schema tmksf to authenticated, service_role, anon;
create function tmksf.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tmksf.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tmksf.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tmksf.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
grant execute on all functions in schema tmksf to authenticated, service_role, anon;

\set pat 'ac300000-0000-0000-0000-000000000001'
\set olive 'ac300000-0000-0000-0000-000000000002'
\set ray 'ac300000-0000-0000-0000-000000000003'

begin;
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@down.test', '{"full_name": "Pat Owner"}'),
  (:'olive', 'olive@down.test', '{"full_name": "Olive Office"}'),
  (:'ray', 'ray@down.test', '{"full_name": "Ray Crew"}');
set local role authenticated;
select tmksf.as_user(:'pat');
select public.create_company('Sketchy Gutters', 'general') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'olive', 'office'), (:'co', :'ray', 'field_crew');
select tmksf.as_nobody();
update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{marketing}', '{"enabled": true}') where id = :'co';
insert into public.clients (company_id, display_name) values (:'co', 'Ann Oak') returning id as ann \gset
insert into public.clients (company_id, display_name, social_photos_opt_out) values (:'co', 'Bob Ash', true) returning id as bob \gset
insert into public.jobs (company_id, client_id, title, status) values (:'co', :'ann', 'Gutters', 'completed') returning id as job \gset
insert into public.jobs (company_id, client_id, title, status) values (:'co', :'ann', 'Driveway', 'completed') returning id as job2 \gset
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes)
values (:'co', 'job', :'job', :'co' || '/job/' || :'job' || '/before.jpg', 'before.jpg', 'image/jpeg', 10) returning id as before_photo \gset
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes)
values (:'co', 'job', :'job', :'co' || '/job/' || :'job' || '/after.jpg', 'after.jpg', 'image/jpeg', 10) returning id as after_photo \gset
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes)
values (:'co', 'job', :'job2', :'co' || '/job/' || :'job2' || '/drive.jpg', 'drive.jpg', 'image/jpeg', 10) returning id as drive_photo \gset

-- Two showcases, each published by the server with a public copy of every photo.
set local role authenticated;
select tmksf.as_user(:'olive');
select public.set_photo_shareable(:'before_photo', true), public.set_photo_shareable(:'after_photo', true), public.set_photo_shareable(:'drive_photo', true);
insert into public.showcases (company_id, job_id, title) values (:'co', :'job', 'Gutters cleared') returning id as sc, token as tok \gset
insert into public.showcases (company_id, job_id, title) values (:'co', :'job2', 'Driveway sealed') returning id as sc2, token as tok2 \gset
insert into public.showcase_photos (company_id, showcase_id, attachment_id, role) values (:'co', :'sc', :'before_photo', 'before'), (:'co', :'sc', :'after_photo', 'after'), (:'co', :'sc2', :'drive_photo', 'photo');
reset role;
create function tmksf.publish(p_showcase uuid) returns void language sql as $$
  update public.showcases set status = 'published', published_at = now(), unpublished_at = null, unpublished_reason = null where id = p_showcase;
  update public.showcase_photos p set public_path = p.company_id || '/showcases/' || p.showcase_id || '/' || p.id || '.jpg' where p.showcase_id = p_showcase;
$$;
set local role service_role;
select tmksf.as_nobody();
select tmksf.publish(:'sc'), tmksf.publish(:'sc2');
select tmksf.check(public.showcase_view(:'tok') ->> 'title' = 'Gutters cleared' and public.showcase_view(:'tok2') is not null, 'both pages are up');
reset role;

\o
\echo 'Only the server reads a showcase for a visitor, and only while Marketing is installed'
\o /dev/null
set local role anon;
select tmksf.check(tmksf.error_of(format('select public.showcase_view(%L)', :'tok')) like '42501:%', 'someone without signing in can''t call showcase_view');
reset role;
set local role authenticated;
select tmksf.as_user(:'olive');
select tmksf.check(tmksf.error_of(format('select public.showcase_view(%L)', :'tok')) like '42501:%', 'nor someone signed in: it''s the server''s');
reset role;
set local role authenticated;
select tmksf.as_user(:'pat');
select public.marketing_set_enabled(:'co', false);
reset role;
set local role service_role;
select tmksf.as_nobody();
select tmksf.check(public.showcase_view(:'tok') is null and public.showcase_view(:'tok2') is null, 'with Marketing uninstalled the pages answer nothing');
select tmksf.check((select count(*) = 2 from public.showcases where status = 'published'), 'though nothing is unpublished');
reset role;
set local role authenticated;
select tmksf.as_user(:'pat');
select public.marketing_set_enabled(:'co', true);
reset role;
set local role service_role;
select tmksf.check(public.showcase_view(:'tok') is not null, 'and installed again, they''re back');
reset role;

\o
\echo 'Deleting a photo that''s on a published showcase'
\o /dev/null
set local role authenticated;
select tmksf.as_user(:'olive');
select tmksf.check(tmksf.error_of(format('delete from public.attachments where id = %L', :'after_photo')) like '22023:%Ask the office to take the showcase down first%',
  'someone deleting a photo that''s on a published showcase is told what to do: have the showcase taken down first');
select tmksf.check(tmksf.error_of(format('delete from public.showcase_photos where showcase_id = %L', :'sc')) = '22023: Unpublish this showcase to change its photos',
  'the office, taking a photo off the showcase itself, is told to unpublish it, as before');
reset role;

\o
\echo 'A photo no longer OK to share'
\o /dev/null
set local role authenticated;
select tmksf.as_user(:'ray');
select public.set_photo_shareable(:'after_photo', false);
reset role;
select tmksf.check((select status = 'unpublished' and unpublished_at is not null and unpublished_reason = 'one of its photos is no longer marked OK to share' from public.showcases where id = :'sc'),
  'un-marking one of its photos takes the showcase down, saying why');
select tmksf.check((select bool_and(public_path is null) from public.showcase_photos where showcase_id = :'sc'), 'its photos have no public copy anymore');
select tmksf.check((select count(*) = 2 from public.stale_public_files where company_id = :'co' and path like :'co' || '/showcases/' || :'sc' || '/%'), 'and the copies are queued for the server to delete');
select tmksf.check((select count(*) = 2 and bool_and(kind = 'showcase' and title = 'A showcase was taken down: Gutters cleared' and body like '%because one of its photos is no longer marked OK to share%' and link = '/marketing?tab=showcases')
  from public.notifications where company_id = :'co' and user_id in (:'pat', :'olive')), 'the owner and the office are told, with why');
select tmksf.check(not exists (select 1 from public.notifications where user_id = :'ray'), 'field crew aren''t');
select tmksf.check((select status = 'published' from public.showcases where id = :'sc2'), 'another showcase stays up');
set local role service_role;
select tmksf.as_nobody();
select tmksf.check(public.showcase_view(:'tok') is null, 'its link finds nothing');
reset role;

\o
\echo 'The client says not to post photos of their property'
\o /dev/null
-- Published again, the photo marked OK again.
set local role authenticated;
select tmksf.as_user(:'olive');
select public.set_photo_shareable(:'after_photo', true);
reset role;
set local role service_role;
select tmksf.as_nobody();
select tmksf.publish(:'sc');
reset role;
select tmksf.check((select unpublished_reason is null and status = 'published' from public.showcases where id = :'sc'), 'published again, the old reason is gone');
delete from public.notifications where company_id = :'co';
set local role authenticated;
select tmksf.as_user(:'olive');
update public.clients set social_photos_opt_out = true where id = :'ann';
reset role;
select tmksf.check((select count(*) = 2 and bool_and(status = 'unpublished' and unpublished_reason = 'the client asked that photos of their property not be posted') from public.showcases where company_id = :'co'),
  'turning it on for a client takes every showcase of their jobs down');
select tmksf.check((select count(*) = 4 from public.notifications where company_id = :'co' and body like '%the client asked that photos of their property not be posted%'), 'and the office is told about each');
select tmksf.check((select bool_and(public_path is null) from public.showcase_photos where company_id = :'co'), 'none of their photos has a public copy');
-- A showcase that isn't published is left as it is.
set local role authenticated;
select tmksf.as_user(:'olive');
update public.clients set social_photos_opt_out = false where id = :'ann';
update public.clients set social_photos_opt_out = true where id = :'ann';
reset role;
select tmksf.check((select count(*) = 4 from public.notifications where company_id = :'co'), 'nothing more is said about showcases that were already down');

\o
\echo 'A job moves to a client who said no'
\o /dev/null
update public.clients set social_photos_opt_out = false where id = :'ann';
set local role service_role;
select tmksf.as_nobody();
select tmksf.publish(:'sc2');
reset role;
update public.jobs set client_id = :'bob' where id = :'job2';
select tmksf.check((select status = 'unpublished' and unpublished_reason like 'the client asked%' from public.showcases where id = :'sc2'), 'its showcase comes down with it');

\o
\echo 'Deleting leaves no copies behind'
\o /dev/null
delete from public.stale_public_files where company_id = :'co';
set local role service_role;
select tmksf.as_nobody();
select tmksf.publish(:'sc');
reset role;
set local role authenticated;
select tmksf.as_user(:'olive');
delete from public.showcases where id = :'sc';
reset role;
select tmksf.check((select count(*) = 2 from public.stale_public_files where path like :'co' || '/showcases/' || :'sc' || '/%'), 'deleting a published showcase queues its copies');
select tmksf.as_nobody();
update public.jobs set client_id = :'ann' where id = :'job2';
set local role service_role;
select tmksf.publish(:'sc2');
reset role;
delete from public.jobs where id = :'job2';
select tmksf.check(not exists (select 1 from public.showcases where id = :'sc2')
  and (select count(*) = 1 from public.stale_public_files where path like :'co' || '/showcases/' || :'sc2' || '/%'), 'deleting its job does too');
set local role authenticated;
select tmksf.as_user(:'olive');
select tmksf.check(tmksf.error_of('select count(*) from public.stale_public_files') like '42501:%', 'the list is the server''s: the office can''t read or change it');
reset role;

rollback;

\o
\echo 'All showcase fix tests passed.'
