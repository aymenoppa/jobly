-- Database tests for 20261113001010_marked_up_photos.sql: a photo drawn on keeps the original and
-- points at a marked-up copy stored beside it (never anywhere else); whoever may change the photo may
-- draw on it, and nobody else; the copy is read by exactly who reads the original; it counts as a
-- file in use; a drawing replaced or taken off, and both files when the photo is removed, go to the
-- Trash; putting the photo back brings its drawing back; and the Photos card reads it.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tmup;
grant usage on schema tmup to authenticated, service_role;
create function tmup.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tmup.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tmup.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
create function tmup.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claims', '', true)
$$;
-- The stored files of these the person asking can read.
create function tmup.reads(p_paths text[]) returns integer language sql stable as $$
  select count(*)::integer from storage.objects o where o.bucket_id = 'files' and o.name = any (p_paths)
$$;
grant execute on all functions in schema tmup to authenticated, service_role;

\set pat 'ab100000-0000-0000-0000-000000000001'
\set ray 'ab100000-0000-0000-0000-000000000002'
\set sam 'ab100000-0000-0000-0000-000000000003'
\set olive 'ab100000-0000-0000-0000-000000000004'

-- Everything below is rolled back at the end.
begin;
-- Pat owns Sketchy Gutters; Olive is in the office; Ray and Sam are field crew. Ray is on the visit
-- at 12 Oak St and takes its photo; Sam isn't on it.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@sketchy.test', '{"full_name": "Pat Owner"}'),
  (:'ray', 'ray@sketchy.test', '{"full_name": "Ray Crew"}'),
  (:'sam', 'sam@sketchy.test', '{"full_name": "Sam Crew"}'),
  (:'olive', 'olive@sketchy.test', '{"full_name": "Olive Office"}');
set local role authenticated;
select tmup.as_user(:'pat');
select public.create_company('Sketchy Gutters', 'general') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'ray', 'field_crew'), (:'co', :'sam', 'field_crew'), (:'co', :'olive', 'office');
insert into public.clients (company_id, display_name) values (:'co', 'Ann Oak') returning id as client \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Gutters') returning id as job \gset
insert into public.visits (company_id, job_id, title, status, scheduled_on) values (:'co', :'job', '12 Oak St', 'in_progress', private.company_today(:'co')) returning id as visit \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'visit', :'ray');
select :'co' || '/visit/' || :'visit' || '/' as dir \gset
select :'dir' || 'aa000000-0000-0000-0000-000000000001.jpg' as original, :'dir' || 'aa000000-0000-0000-0000-000000000002.jpg' as drawn,
       :'dir' || 'aa000000-0000-0000-0000-000000000003.jpg' as redrawn, :'dir' || 'aa000000-0000-0000-0000-000000000004.jpg' as again \gset
insert into storage.objects (bucket_id, name, owner) values ('files', :'original', :'ray'), ('files', :'drawn', :'ray'), ('files', :'redrawn', :'olive'), ('files', :'again', :'pat');

\o
\echo 'A new photo can come drawn on, its drawing beside it'
\o /dev/null
set local role authenticated;
select tmup.as_user(:'ray');
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes, marked_path)
values (:'co', 'visit', :'visit', :'original', 'gutter.jpg', 'image/jpeg', 1000, :'drawn') returning id as photo \gset
select tmup.check((select marked_path = :'drawn' and marked_at is not null from public.attachments where id = :'photo'), 'the crew adds a photo with its drawing, dated as it''s drawn');
select tmup.check(tmup.error_of(format('insert into public.attachments (company_id, owner_type, owner_id, path, file_name, marked_path) values (%L, %L, %L, %L, %L, %L)',
  :'co', 'visit', :'visit', :'dir' || 'bb.jpg', 'x.jpg', :'co' || '/visit/' || gen_random_uuid() || '/bb-drawn.jpg')) like '22023:%', 'a drawing in another folder is turned down');
select tmup.check(tmup.error_of(format('insert into public.attachments (company_id, owner_type, owner_id, path, file_name, marked_path) values (%L, %L, %L, %L, %L, %L)',
  :'co', 'visit', :'visit', :'dir' || 'bb.jpg', 'x.jpg', :'dir' || 'sub/bb-drawn.jpg')) like '22023:%', 'and one in a folder under it');
select tmup.check(tmup.error_of(format('insert into public.attachments (company_id, owner_type, owner_id, path, file_name, marked_path) values (%L, %L, %L, %L, %L, %L)',
  :'co', 'visit', :'visit', :'dir' || 'bb.jpg', 'x.jpg', :'dir' || 'bb.jpg')) like '22023:%', 'and the original itself');
select tmup.check(tmup.error_of(format('insert into public.attachments (company_id, owner_type, owner_id, path, file_name, marked_path) values (%L, %L, %L, %L, %L, %L)',
  :'co', 'visit', :'visit', :'dir' || 'bb.jpg', 'x.jpg', :'dir' || '..')) like '22023:%', 'and a way out of the folder');

\o
\echo 'Read by exactly who reads the original'
\o /dev/null
select tmup.check(tmup.reads(array[:'original', :'drawn', :'redrawn']) = 3, 'the crew on the visit reads the photo and its drawings');
select tmup.as_user(:'sam');
select tmup.check(tmup.reads(array[:'original', :'drawn', :'redrawn']) = 0, 'someone not on the visit reads neither');
select tmup.as_user(:'olive');
select tmup.check(tmup.reads(array[:'original', :'drawn', :'redrawn']) = 3, 'the office reads both');

\o
\echo 'Whoever may change the photo may draw on it'
\o /dev/null
select tmup.as_user(:'sam');
update public.attachments set marked_path = :'redrawn' where id = :'photo';
-- Ray, on the visit, sees it.
select tmup.as_user(:'ray');
select tmup.check((select marked_path from public.attachments where id = :'photo') = :'drawn', 'someone who didn''t take it and isn''t in the office can''t');
select tmup.as_user(:'olive');
update public.attachments set marked_path = :'redrawn' where id = :'photo';
select tmup.check((select marked_path from public.attachments where id = :'photo') = :'redrawn', 'the office can, and the new drawing replaces the old');
select tmup.as_user(:'ray');
select tmup.check(tmup.error_of(format('update public.attachments set marked_path = %L where id = %L', :'co' || '/job/' || :'job' || '/x.jpg', :'photo')) like '22023:%',
  'whoever took it can''t point it at a file somewhere else');
select tmup.check(exists (select 1 from public.record_photos(:'co', :'job') where id = :'photo' and marked_path = :'redrawn'), 'the Photos card reads the drawing');
reset role;
select tmup.check((select source = 'visit_photo' and label like 'Visit photo · Job #% (drawn on)' and file_name = 'gutter (drawn on).jpg' and restore is null
  from public.trashed_files where path = :'drawn'), 'the drawing it replaced is in the Trash, named as the photo''s drawing');
select tmup.check(private.stored_path_in_use(:'co', :'redrawn') and not private.stored_path_in_use(:'co', :'drawn'), 'the drawing shown is a file in use; the one replaced isn''t');

\o
\echo 'The drawing off, and the photo removed'
\o /dev/null
set local role authenticated;
select tmup.as_user(:'pat');
update public.attachments set marked_path = null where id = :'photo';
select tmup.check((select marked_path is null and marked_at is null from public.attachments where id = :'photo'), 'taking the drawing off shows the original again');
reset role;
select tmup.check(exists (select 1 from public.trashed_files where path = :'redrawn'), 'and the drawing goes to the Trash');
-- Drawn on once more, then removed by an app from before this (it knows only the row).
set local role authenticated;
update public.attachments set marked_path = :'again' where id = :'photo';
select tmup.as_user(:'ray');
delete from public.attachments where id = :'photo';
reset role;
select tmup.check((select count(*) = 2 from public.trashed_files where path in (:'original', :'again')), 'removing the photo puts the photo and its drawing in the Trash');
select tmup.check((select restore ->> 'marked_path' = :'again' from public.trashed_files where path = :'original'), 'the photo remembers its drawing there');

\o
\echo 'Putting the photo back brings its drawing'
\o /dev/null
select id as photo_trash from public.trashed_files where path = :'original' \gset
set local role authenticated;
select tmup.as_user(:'pat');
select tmup.check(public.drive_restore('other', :'photo_trash') = 'restored', 'the owner puts the photo back');
reset role;
select tmup.check((select marked_path = :'again' from public.attachments where id = :'photo'), 'with its drawing');
select tmup.check(not exists (select 1 from public.trashed_files where path in (:'original', :'again')), 'and neither is in the Trash now');

\o
\echo 'A new original drops the drawing'
\o /dev/null
select tmup.as_nobody();
update public.attachments set path = :'dir' || 'cc.jpg' where id = :'photo';
select tmup.check((select marked_path is null from public.attachments where id = :'photo'), 'a photo nobody drew on has no drawing');
select tmup.check(exists (select 1 from public.trashed_files where path = :'again'), 'and the old drawing is in the Trash');

rollback;

\o
\echo 'All marked-up photo tests passed.'
