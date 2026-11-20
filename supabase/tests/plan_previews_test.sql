-- Database tests for plan files' preview copies (20261118000100_plan_previews.sql): a copy is read
-- by exactly the people who read its file (crews never get an office-only file's copy, nor an older
-- version's), a row can only name its own copy, which never changes, Drive's lists return it, and a
-- file deleted for good hands its copy over with it.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpp;
grant usage on schema tpp to authenticated, service_role;
create function tpp.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
-- The error a statement raises, as "SQLSTATE: message" ('none' when it doesn't).
create function tpp.error_of(p_sql text) returns text language plpgsql as $$
begin
  begin execute p_sql; exception when others then return sqlstate || ': ' || sqlerrm; end;
  return 'none';
end $$;
create function tpp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- The company's stored plans/ files the person asking reads, by file name alone, in one fixed order.
create function tpp.plans(p_company uuid) returns text[] language sql stable as $$
  select coalesce(array_agg(regexp_replace(o.name, '^.*/', '') order by o.name collate "C"), '{}')
  from storage.objects o where o.bucket_id = 'files' and starts_with(o.name, p_company::text || '/plans/')
$$;
-- A list in that order, to compare with it.
create function tpp.sorted(p text[]) returns text[] language sql immutable as $$
  select array(select x from unnest(p) x order by x collate "C")
$$;
-- The person asking reads exactly these plans/ files; a failed check says which differ.
create function tpp.reads(p_company uuid, p_files text[], p_what text) returns void language plpgsql as $$
declare v_read text[] := tpp.plans(p_company);
begin
  if v_read is distinct from tpp.sorted(p_files) then
    raise exception 'FAIL: % (also reads: %; doesn''t read: %)', p_what,
      coalesce((select string_agg(x, ', ') from unnest(v_read) x where x <> all (p_files)), 'nothing'),
      coalesce((select string_agg(x, ', ') from unnest(p_files) x where x <> all (v_read)), 'nothing');
  end if;
  raise notice 'ok - %', p_what;
end $$;
-- Stored files handed over to be removed, by file name alone, in a line: "a+b" ("kept" for none).
create function tpp.files(p_paths text[]) returns text language sql as $$
  select coalesce(nullif(array_to_string(array(select regexp_replace(p, '^.*/', '') collate "C" from unnest(p_paths) p order by 1), '+'), ''), 'kept')
$$;
grant execute on all functions in schema tpp to authenticated, service_role;

\set pia 'a9a90000-0000-0000-0000-000000000001'
\set oli 'a9a90000-0000-0000-0000-000000000002'
\set lou 'a9a90000-0000-0000-0000-000000000003'
\set fay 'a9a90000-0000-0000-0000-000000000004'
\set gus 'a9a90000-0000-0000-0000-000000000005'
\set sal 'a9a90000-0000-0000-0000-000000000006'

-- Pia owns Papa Paving; Oli is in the office; Lou leads a crew; Fay is field crew on the visit to
-- Ann's job; Gus is field crew with no visits; Sal signs in for a sub on that visit too.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pia', 'pia@papa.test', '{"full_name": "Pia Owner"}'),
  (:'oli', 'oli@papa.test', '{"full_name": "Oli Office"}'),
  (:'lou', 'lou@papa.test', '{"full_name": "Lou Lead"}'),
  (:'fay', 'fay@papa.test', '{"full_name": "Fay Field"}'),
  (:'gus', 'gus@papa.test', '{"full_name": "Gus Field"}'),
  (:'sal', 'sub-sal@papa-subs.invalid', '{"full_name": "Sal Sealing"}');
update auth.users set raw_app_meta_data = '{"jobly_sub": "papa:1"}' where id = :'sal';

begin;
set local role authenticated;
select tpp.as_user(:'pia');
select public.create_company('Papa Paving', 'paving') as co \gset
insert into public.memberships (company_id, user_id, role) values
  (:'co', :'oli', 'office'), (:'co', :'lou', 'crew_lead'), (:'co', :'fay', 'field_crew'), (:'co', :'gus', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Ann Client') returning id as c1 \gset
insert into public.properties (company_id, client_id, line1) values (:'co', :'c1', '1 Oak St') returning id as p1 \gset
insert into public.jobs (company_id, client_id, property_id, title) values (:'co', :'c1', :'p1', 'Driveway') returning id as j1 \gset
insert into public.visits (company_id, job_id, property_id, title, scheduled_on) values (:'co', :'j1', :'p1', 'Pave the drive', current_date) returning id as v1 \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'v1', :'fay');
insert into public.subcontractors (company_id, name) values (:'co', 'Sal''s Sealing') returning id as sub \gset
commit;
insert into public.memberships (company_id, user_id, role, subcontractor_id) values (:'co', :'sal', 'subcontractor', :'sub');
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'v1', :'sal');

-- On Ann's job: a site photo for the crew, in two versions (each with its copy), and the signed bid
-- photo, the office's only (with its copy).
\set site1 'a9a90000-0000-0000-0000-0000000000a1'
\set site2 'a9a90000-0000-0000-0000-0000000000a2'
\set bid 'a9a90000-0000-0000-0000-0000000000b1'
begin;
set local role authenticated;
select tpp.as_user(:'oli');
insert into public.plan_files (id, company_id, job_id, title, path, preview_path, file_name, content_type, crew_visible) values
  (:'site1', :'co', :'j1', 'Site photo', :'co' || '/plans/' || :'site1' || '.jpg', :'co' || '/plans/' || :'site1' || '.preview.webp', 'site.jpg', 'image/jpeg', true),
  (:'bid', :'co', :'j1', 'Signed bid', :'co' || '/plans/' || :'bid' || '.jpg', :'co' || '/plans/' || :'bid' || '.preview.webp', 'bid.jpg', 'image/jpeg', false);
insert into public.plan_files (id, company_id, replaces_id, title, path, preview_path, file_name, content_type, crew_visible) values
  (:'site2', :'co', :'site1', 'Site photo', :'co' || '/plans/' || :'site2' || '.png', :'co' || '/plans/' || :'site2' || '.preview.jpg', 'site.png', 'image/png', true);
commit;

-- What's stored: each file and its copy, and a copy no row names (its file's save failed), stored by Lou.
insert into storage.objects (bucket_id, name, owner) select 'files', :'co' || '/plans/' || x.name, x.owner
from (values
  (:'site1' || '.jpg', null::uuid), (:'site1' || '.preview.webp', null),
  (:'site2' || '.png', null), (:'site2' || '.preview.jpg', null),
  (:'bid' || '.jpg', null), (:'bid' || '.preview.webp', null),
  ('a9a90000-0000-0000-0000-0000000000c9.preview.webp', :'lou'::uuid)
) as x(name, owner);

\o
\echo 'Who reads a preview copy'
\o /dev/null

begin;
set local role authenticated;
select tpp.as_user(:'fay');
select tpp.reads(:'co', array[:'site2' || '.png', :'site2' || '.preview.jpg'],
  'field crew on the job read the current photo for the crew and its copy: not the office''s bid or its copy, the older version''s copy, or a copy no row names');
select tpp.as_user(:'gus');
select tpp.reads(:'co', '{}', 'field crew with no visits there read no file and no copy');
select tpp.as_user(:'lou');
select tpp.reads(:'co', array[:'site2' || '.png', :'site2' || '.preview.jpg'],
  'a crew lead reads the same: not the bid''s copy, nor the stray copy, though they stored it');
select tpp.as_user(:'sal');
select tpp.reads(:'co', array[:'site2' || '.png', :'site2' || '.preview.jpg'], 'a sub on the job reads the photo for the crew and its copy, and not the bid''s');
select tpp.as_user(:'oli');
select tpp.reads(:'co', array[:'site1' || '.jpg', :'site1' || '.preview.webp', :'site2' || '.png', :'site2' || '.preview.jpg',
  :'bid' || '.jpg', :'bid' || '.preview.webp', 'a9a90000-0000-0000-0000-0000000000c9.preview.webp'], 'the office reads every file and copy, as every plan file before');
rollback;

-- Marked for the crew, the bid's copy is theirs to open too.
update public.plan_files set crew_visible = true where id = :'bid';
begin;
set local role authenticated;
select tpp.as_user(:'fay');
select tpp.check(tpp.plans(:'co') @> array[:'bid' || '.preview.webp'], 'a copy follows its row: marked for the crew, the crew reads it');
rollback;
update public.plan_files set crew_visible = false where id = :'bid';

\o
\echo 'A row names only its own copy'
\o /dev/null

begin;
set local role authenticated;
select tpp.as_user(:'lou');
-- Lou adds a photo for the crew whose "copy" is the office's bid: it would hand the crew the bid.
select tpp.check(tpp.error_of(format('insert into public.plan_files (company_id, job_id, title, path, preview_path, file_name, crew_visible) values (%L, %L, %L, %L, %L, %L, true)',
  :'co', :'j1', 'Trick', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000d1.jpg', :'co' || '/plans/' || :'bid' || '.jpg', 'trick.jpg')) like '23514:%',
  'a row can''t name another file as its copy');
select tpp.check(tpp.error_of(format('insert into public.plan_files (company_id, job_id, title, path, preview_path, file_name, crew_visible) values (%L, %L, %L, %L, %L, %L, true)',
  :'co', :'j1', 'Trick', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000d1.jpg', :'co' || '/plans/' || :'bid' || '.preview.webp', 'trick.jpg')) like '23514:%',
  'nor another file''s copy');
select tpp.check(tpp.error_of(format('insert into public.plan_files (company_id, job_id, title, path, preview_path, file_name, crew_visible) values (%L, %L, %L, %L, %L, %L, true)',
  :'co', :'j1', 'Trick', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000d1.jpg', :'co' || '/visit/' || :'v1' || '/a9a90000-0000-0000-0000-0000000000d1.preview.webp', 'trick.jpg')) like '23514:%',
  'nor a copy stored anywhere but next to its file');
select tpp.check(tpp.error_of(format('insert into public.plan_files (company_id, job_id, title, path, preview_path, file_name, crew_visible) values (%L, %L, %L, %L, %L, %L, true)',
  :'co', :'j1', 'Photo', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000d2.jpg', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000d2.preview.webp', 'photo.jpg')) = 'none',
  'a crew lead adds a photo with its own copy');
select tpp.check(tpp.error_of(format('insert into public.plan_files (company_id, job_id, title, path, file_name, crew_visible) values (%L, %L, %L, %L, %L, true)',
  :'co', :'j1', 'Plan', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000d3.pdf', 'plan.pdf')) = 'none',
  'or a file with none');
rollback;

begin;
set local role authenticated;
select tpp.as_user(:'oli');
update public.plan_files set preview_path = null where id = :'bid';
update public.plan_files set preview_path = :'co' || '/plans/' || :'bid' || '.preview.jpg' where id = :'bid';
select tpp.check((select preview_path = :'co' || '/plans/' || :'bid' || '.preview.webp' from public.plan_files where id = :'bid'), 'nobody changes a file''s copy by hand');
-- A new version has its own copy, or none: never the one before's.
insert into public.plan_files (company_id, replaces_id, title, path, file_name, content_type, crew_visible)
  values (:'co', :'bid', 'Signed bid', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000b2.pdf', 'bid.pdf', 'application/pdf', false) returning id as bid2 \gset
select tpp.check((select preview_path is null from public.plan_files where id = :'bid2'), 'a new version doesn''t take the copy of the one it replaces');
rollback;

select tpp.check(private.stored_path_in_use(:'co', :'co' || '/plans/' || :'site1' || '.preview.webp'), 'a copy is in use while its row is there');
select tpp.check(not private.stored_path_in_use(:'co', :'co' || '/plans/a9a90000-0000-0000-0000-0000000000c9.preview.webp'), 'and one no row names isn''t');

\o
\echo 'Drive''s lists'
\o /dev/null

begin;
set local role authenticated;
select tpp.as_user(:'oli');
select tpp.check((select array_agg(regexp_replace(preview_path, '^.*/', '') order by title) from public.drive_list(:'co', 'client', :'c1'))
  = array[:'bid' || '.preview.webp', :'site2' || '.preview.jpg'], 'Drive''s list has each current file''s copy');
select tpp.check((select array_agg(regexp_replace(preview_path, '^.*/', '') order by preview_path collate "C") from public.drive_versions(:'site2'))
  = tpp.sorted(array[:'site2' || '.preview.jpg', :'site1' || '.preview.webp']), 'and so do its versions');
select tpp.as_user(:'fay');
select tpp.check((select array_agg(regexp_replace(preview_path, '^.*/', '')) from public.drive_versions(:'site2')) = array[:'site2' || '.preview.jpg'],
  'a crew''s list of versions has only the current one''s copy');
rollback;

\o
\echo 'A copy goes with its file'
\o /dev/null

-- The site photo (both versions) goes in the Trash, and its 30 days are up: the purge hands over
-- both files and both copies, and counts two files.
begin;
set local role authenticated;
select tpp.as_user(:'oli');
select tpp.check(public.drive_trash_file(:'site2') = 2, 'the photo goes in the Trash, both versions');
commit;
select tpp.check((select array_agg(regexp_replace(name, '^.*/', '') order by name collate "C") from storage.objects where name like :'co' || '/plans/' || :'site1' || '%')
  = array[:'site1' || '.jpg', :'site1' || '.preview.webp'], 'in the Trash, a file and its copy are both still stored');
begin;
select set_config('jobly.trash', 'on', true);
update public.plan_files set deleted_at = deleted_at - interval '40 days' where id in (:'site1', :'site2');
commit;
set role service_role;
select string_agg(source || ':' || deleted || ':' || tpp.files(paths), ',') as purged from public.trash_purge(now(), 1000) where company_id = :'co' \gset
reset role;
select tpp.check(:'purged' = format('plan_files:2:%s.jpg+%s.preview.webp+%s.png+%s.preview.jpg', :'site1', :'site1', :'site2', :'site2'),
  'the purge hands over both files and both copies, and counts two files: ' || :'purged');

-- The owner deletes the bid for good from the Trash: its copy goes too.
begin;
set local role authenticated;
select tpp.as_user(:'pia');
select public.drive_trash_file(:'bid');
select string_agg(kind || ':' || tpp.files(paths), ',') as forever from public.trash_delete_forever(:'co', jsonb_build_array(jsonb_build_object('kind', 'file', 'id', :'bid'))) \gset
commit;
select tpp.check(:'forever' = format('file:%s.jpg+%s.preview.webp', :'bid', :'bid'), 'Delete forever hands over the file and its copy: ' || :'forever');
select tpp.check(not exists (select 1 from public.plan_files where company_id = :'co'), 'and no rows are left');

-- Left as it was found, for the tests after this one.
delete from storage.objects where name like :'co' || '/%';
delete from public.companies where id = :'co';
set client_min_messages = warning;
drop schema tpp cascade;
reset client_min_messages;

\o
\echo 'All plan preview tests passed.'
