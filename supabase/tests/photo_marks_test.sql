-- Database tests for 20261113001500_photo_marks.sql: a photo's marks are kept on its row by whoever
-- may change the photo (and nobody else), come in with a photo added already drawn on, must be an
-- object of a sensible size, and are left as they were by an app from before this, which is why
-- they name the drawing they made.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tpmk;
grant usage on schema tpmk to authenticated, service_role;
create function tpmk.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tpmk.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function tpmk.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
grant execute on all functions in schema tpmk to authenticated, service_role;

\set pat 'ab150000-0000-0000-0000-000000000001'
\set ray 'ab150000-0000-0000-0000-000000000002'
\set sam 'ab150000-0000-0000-0000-000000000003'

-- Everything below is rolled back at the end.
begin;
-- Pat owns Chalk Line Roofing; Ray and Sam are field crew. Ray is on the visit and takes its photo.
insert into auth.users (id, email, raw_user_meta_data) values
  (:'pat', 'pat@chalk.test', '{"full_name": "Pat Owner"}'),
  (:'ray', 'ray@chalk.test', '{"full_name": "Ray Crew"}'),
  (:'sam', 'sam@chalk.test', '{"full_name": "Sam Crew"}');
set local role authenticated;
select tpmk.as_user(:'pat');
select public.create_company('Chalk Line Roofing', 'general') as co \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'ray', 'field_crew'), (:'co', :'sam', 'field_crew');
insert into public.clients (company_id, display_name) values (:'co', 'Ann Oak') returning id as client \gset
insert into public.jobs (company_id, client_id, title) values (:'co', :'client', 'Roof') returning id as job \gset
insert into public.visits (company_id, job_id, title, status, scheduled_on) values (:'co', :'job', '12 Oak St', 'in_progress', private.company_today(:'co')) returning id as visit \gset
insert into public.visit_assignees (company_id, visit_id, user_id) values (:'co', :'visit', :'ray'), (:'co', :'visit', :'sam');
select :'co' || '/visit/' || :'visit' || '/' as dir \gset
select :'dir' || 'aa000000-0000-0000-0000-000000000001.jpg' as original, :'dir' || 'aa000000-0000-0000-0000-000000000002.jpg' as drawn,
       :'dir' || 'aa000000-0000-0000-0000-000000000003.jpg' as redrawn \gset
select jsonb_build_object('v', 1, 'for', :'drawn', 'width', 2000, 'height', 1500,
  'marks', jsonb_build_array(jsonb_build_object('kind', 'box', 'color', '#e5243b', 'width', 'thin', 'from', jsonb_build_object('x', 10, 'y', 10), 'to', jsonb_build_object('x', 200, 'y', 150)))) as marks \gset

\o
\echo 'A photo keeps the marks drawn on it'
\o /dev/null
set local role authenticated;
select tpmk.as_user(:'ray');
insert into public.attachments (company_id, owner_type, owner_id, path, file_name, content_type, size_bytes, marked_path, marks)
values (:'co', 'visit', :'visit', :'original', 'ridge.jpg', 'image/jpeg', 1000, :'drawn', :'marks') returning id as photo \gset
select tpmk.check((select marks ->> 'for' = marked_path and jsonb_array_length(marks -> 'marks') = 1 from public.attachments where id = :'photo'),
  'a photo added already drawn on comes with its marks, named for its drawing');
update public.attachments set marked_path = :'redrawn', marks = jsonb_set(:'marks'::jsonb, '{for}', to_jsonb(:'redrawn'::text)) where id = :'photo';
select tpmk.check((select marks ->> 'for' = :'redrawn' from public.attachments where id = :'photo'), 'whoever took it draws again, and the marks follow the new drawing');

\o
\echo 'Only whoever may change the photo'
\o /dev/null
select tpmk.as_user(:'sam');
update public.attachments set marks = null where id = :'photo';
select tpmk.as_user(:'ray');
select tpmk.check((select marks is not null from public.attachments where id = :'photo'), 'a crewmate who didn''t take it can''t change its marks');

\o
\echo 'An app from before this leaves them, and they stop counting'
\o /dev/null
-- It knows only marked_path: a new drawing, the marks untouched.
update public.attachments set marked_path = :'drawn' where id = :'photo';
select tpmk.check((select marks ->> 'for' <> marked_path from public.attachments where id = :'photo'), 'drawn on by an older app: the marks name another drawing, so they aren''t used');
update public.attachments set marked_path = null where id = :'photo';
select tpmk.check((select marked_path is null and marks is not null from public.attachments where id = :'photo'), 'the drawing taken off by an older app: marks for a drawing that''s gone');

\o
\echo 'What can be kept'
\o /dev/null
select tpmk.check(tpmk.error_of(format('update public.attachments set marks = %L where id = %L', '[1, 2]', :'photo')) like '23514:%', 'a list isn''t marks');
select tpmk.check(tpmk.error_of(format('update public.attachments set marks = %L where id = %L', '"x"', :'photo')) like '23514:%', 'nor a word');
select tpmk.check(tpmk.error_of(format('update public.attachments set marks = jsonb_build_object(''v'', 1, ''pad'', repeat(''x'', 500000)) where id = %L', :'photo')) like '23514:%',
  'nor a file''s worth');
update public.attachments set marks = null where id = :'photo';
select tpmk.check((select marks is null from public.attachments where id = :'photo'), 'and none is fine');

rollback;

\o
\echo 'All photo marks tests passed.'
