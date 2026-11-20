-- Database tests for sharing a guide by link (20261117000200_guide_sharing.sql): owners and admins
-- who edit guides decide who a guide is shared with, the office sees it, crews and other companies
-- see nothing; the link is never the browser's to choose; and public.guide_share_view says nothing
-- of a guide to anyone who may not open it.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tgs;
grant usage on schema tgs to authenticated, service_role, anon;
create function tgs.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function tgs.expect_error(p_sql text, p_what text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then raise notice 'ok - % (%)', p_what, sqlerrm; return; end;
  raise exception 'FAIL (expected an error): %', p_what;
end $$;
grant execute on all functions in schema tgs to authenticated, service_role, anon;

insert into auth.users (id, email, raw_user_meta_data) values
  ('9f000000-0000-4000-8000-000000000001', 'owner@peak.test', '{"full_name": "Pat Owner"}'),
  ('9f000000-0000-4000-8000-000000000002', 'office@peak.test', '{"full_name": "Olive Office"}'),
  ('9f000000-0000-4000-8000-000000000003', 'crew@peak.test', '{"full_name": "Cal Crew"}'),
  ('9f000000-0000-4000-8000-000000000004', 'owner@ridge.test', '{"full_name": "Rae Owner"}'),
  ('9f000000-0000-4000-8000-000000000005', 'admin@peak.test', '{"full_name": "Ada Admin"}');

begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000004", "role": "authenticated"}', true);
select public.create_company('Ridge Roofing', 'roofing') as other \gset
insert into public.sop_pages (company_id, title) values (:'other', 'Their guide') returning id as theirs \gset
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000001", "role": "authenticated"}', true);
select public.create_company('Peak Lawn', 'paving') as co \gset
insert into public.sop_categories (company_id, name) values (:'co', 'Aftercare') returning id as cat \gset
insert into public.sop_pages (company_id, title, category_id, body_html, cover_path) values (:'co', 'Caring for new sod', :'cat', '<p>Water it twice a day.</p>', :'co' || '/kb/cover.jpg') returning id as sod \gset
insert into public.sop_pages (company_id, title, status, body_html) values (:'co', 'Pricing notes', 'draft', '<p>Not ready.</p>') returning id as draft \gset
commit;
reset role;
insert into public.memberships (company_id, user_id, role) values
  (:'co', '9f000000-0000-4000-8000-000000000002', 'office'),
  (:'co', '9f000000-0000-4000-8000-000000000003', 'field_crew'),
  (:'co', '9f000000-0000-4000-8000-000000000005', 'admin');

-- ===== The owner shares a guide ================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000001", "role": "authenticated"}', true);
insert into public.sop_shares (page_id, company_id, token, access) values (:'sod', :'co', '00000000000000000000000000000000', 'restricted');
select tgs.check((select token <> '00000000000000000000000000000000' and token ~ '^[0-9a-f]{32}$' from public.sop_shares where page_id = :'sod'), 'a share''s link is random, whatever the browser sent');
select tgs.check((select access = 'restricted' and created_by = '9f000000-0000-4000-8000-000000000001' from public.sop_shares where page_id = :'sod'), 'it starts for only the people added, and says who made it');
select token as link from public.sop_shares where page_id = :'sod' \gset
update public.sop_shares set token = '11111111111111111111111111111111', access = 'anyone' where page_id = :'sod';
select tgs.check((select token = :'link' and access = 'anyone' from public.sop_shares where page_id = :'sod'), 'the browser changes who may open it, never the link');
update public.sop_shares set access = 'restricted' where page_id = :'sod';
select tgs.expect_error(format('update public.sop_shares set access = %L where page_id = %L', 'everyone', :'sod'), 'who may open it is one of the two choices');
select tgs.expect_error(format('insert into public.sop_shares (page_id, company_id) values (%L, %L)', :'theirs', :'co'), 'a share is for the company''s own guide');
select tgs.expect_error(format('insert into public.sop_shares (page_id, company_id) values (%L, %L)', :'theirs', :'other'), 'and never made for another company');

insert into public.sop_share_people (company_id, page_id, email, last_opened_at) values (:'co', :'sod', 'dana@example.com', now());
select tgs.check((select last_opened_at is null and added_by = '9f000000-0000-4000-8000-000000000001' from public.sop_share_people where email = 'dana@example.com'), 'a person is added by whoever added them, not yet having opened it');
select tgs.expect_error(format('insert into public.sop_share_people (company_id, page_id, email) values (%L, %L, %L)', :'co', :'sod', 'dana@example.com'), 'a person is added once');
select tgs.expect_error(format('insert into public.sop_share_people (company_id, page_id, email) values (%L, %L, %L)', :'co', :'sod', 'Dana@Example.com'), 'in one spelling');
select tgs.expect_error(format('insert into public.sop_share_people (company_id, page_id, email) values (%L, %L, %L)', :'co', :'sod', 'not an address'), 'by a whole email address');
select tgs.expect_error(format('insert into public.sop_share_people (company_id, page_id, email) values (%L, %L, %L)', :'co', :'draft', 'dana@example.com'), 'on a guide that has a share');
update public.sop_share_people set email = 'someone@else.test', last_opened_at = now() where email = 'dana@example.com';
select tgs.check((select count(*) = 1 from public.sop_share_people where page_id = :'sod' and email = 'dana@example.com' and last_opened_at is null), 'and stays the address they were added as');
commit;
reset role;

-- ===== Who sees and changes it ==================================================================
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000005", "role": "authenticated"}', true);
insert into public.sop_share_people (company_id, page_id, email) values (:'co', :'sod', 'sub@example.com');
select tgs.check((select count(*) from public.sop_share_people where page_id = :'sod') = 2, 'an admin shares it too');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000002", "role": "authenticated"}', true);
select tgs.check((select count(*) from public.sop_shares where page_id = :'sod') = 1 and (select count(*) from public.sop_share_people where page_id = :'sod') = 2, 'the office sees that a guide is shared, and with whom');
select tgs.expect_error(format('insert into public.sop_share_people (company_id, page_id, email) values (%L, %L, %L)', :'co', :'sod', 'friend@example.com'), 'but doesn''t add people');
select tgs.expect_error(format('insert into public.sop_shares (page_id, company_id) values (%L, %L)', :'draft', :'co'), 'or share a guide');
update public.sop_shares set access = 'anyone' where page_id = :'sod';
delete from public.sop_share_people where page_id = :'sod';
delete from public.sop_shares where page_id = :'sod';
commit;
reset role;
select tgs.check((select access from public.sop_shares where page_id = :'sod') = 'restricted' and (select count(*) from public.sop_share_people where page_id = :'sod') = 2, 'or open it to anyone, or take anyone off');
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000003", "role": "authenticated"}', true);
select tgs.check((select count(*) from public.sop_shares) = 0 and (select count(*) from public.sop_share_people) = 0, 'the crew sees nothing of who guides are shared with');
commit;
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000004", "role": "authenticated"}', true);
select tgs.check((select count(*) from public.sop_shares) = 0 and (select count(*) from public.sop_share_people) = 0, 'nor does another company');
select tgs.expect_error(format('select public.guide_share_view(%L)', :'link'), 'and nobody signed in reads a shared guide through the server''s function');
commit;
begin;
set local role anon;
select tgs.expect_error(format('select public.guide_share_view(%L)', :'link'), 'nor does anyone without a sign-in');
select tgs.expect_error('select count(*) from public.sop_shares', 'who reads neither table');
commit;
reset role;

-- An admin whose role can't edit guides doesn't share them either.
insert into public.company_roles (company_id, name, base_role, permissions) values (:'co', 'Bookkeeper', 'admin', array['invoices']) returning id as bookkeeper \gset
update public.memberships set role_id = :'bookkeeper' where company_id = :'co' and user_id = '9f000000-0000-4000-8000-000000000005';
begin;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub": "9f000000-0000-4000-8000-000000000005", "role": "authenticated"}', true);
select tgs.check((select count(*) from public.sop_shares) = 0, 'an admin whose role doesn''t edit guides sees no shares');
select tgs.expect_error(format('insert into public.sop_share_people (company_id, page_id, email) values (%L, %L, %L)', :'co', :'sod', 'friend@example.com'), 'and adds nobody');
commit;
reset role;

-- ===== What the link shows ======================================================================
begin;
set local role service_role;
select set_config('request.jwt.claims', '{"role": "service_role"}', true);
select tgs.check(public.guide_share_view('ffffffffffffffffffffffffffffffff') is null and public.guide_share_view('nonsense') is null and public.guide_share_view(null) is null, 'a link that isn''t one shows nothing');
select public.guide_share_view(:'link') as locked \gset
select tgs.check((:'locked'::jsonb ->> 'allowed') = 'false' and not (:'locked'::jsonb ?| array['title', 'body_html', 'cover_path', 'category']), 'a guide for certain people says nothing of itself to a stranger');
select tgs.check((:'locked'::jsonb ->> 'company_id') = :'co' and (:'locked'::jsonb ->> 'access') = 'restricted', 'only whose it is, for the page to ask for an address');
select tgs.check((public.guide_share_view(:'link', 'stranger@example.com') ->> 'allowed') = 'false', 'nor to an address that wasn''t added');
select public.guide_share_view(:'link', '  Dana@Example.com ') as open \gset
select tgs.check((:'open'::jsonb ->> 'allowed') = 'true' and (:'open'::jsonb ->> 'title') = 'Caring for new sod' and (:'open'::jsonb ->> 'body_html') = '<p>Water it twice a day.</p>', 'a person who was added reads it, however they typed their address');
select tgs.check((:'open'::jsonb ->> 'category') = 'Aftercare' and (:'open'::jsonb ->> 'cover_path') = :'co' || '/kb/cover.jpg' and (:'open'::jsonb ->> 'page_id') = :'sod', 'with its category and cover');
select tgs.check((select last_opened_at is null from public.sop_share_people where email = 'dana@example.com'), 'looking doesn''t count as opening it');
select public.guide_share_view(:'link', 'dana@example.com', true);
select tgs.check((select last_opened_at is not null from public.sop_share_people where email = 'dana@example.com') and (select last_opened_at is null from public.sop_share_people where email = 'sub@example.com'), 'opening it is noted for that person only');
-- By their row instead of their address, as the page's pictures ask.
select id as dana from public.sop_share_people where email = 'dana@example.com' \gset
select tgs.check((:'open'::jsonb ->> 'person_id') = :'dana', 'it says which person it opened for');
select tgs.check((public.guide_share_view(:'link', p_person => :'dana') ->> 'allowed') = 'true', 'a person''s own row opens it too');
select tgs.check((public.guide_share_view(:'link', p_person => gen_random_uuid()) ->> 'allowed') = 'false', 'a row that isn''t one opens nothing');
insert into public.sop_shares (page_id, company_id, token) values (:'draft', :'co', '44444444444444444444444444444444');
update public.sop_pages set status = 'published' where id = :'draft';
select tgs.check((public.guide_share_view('44444444444444444444444444444444', p_person => :'dana') ->> 'allowed') = 'false', 'nor does a person''s row from another guide');
update public.sop_pages set status = 'draft' where id = :'draft';
delete from public.sop_shares where page_id = :'draft';

-- For anyone with the link.
update public.sop_shares set access = 'anyone' where page_id = :'sod';
select tgs.check((public.guide_share_view(:'link') ->> 'title') = 'Caring for new sod', 'a guide for anyone with the link opens with no address');
update public.sop_shares set access = 'restricted' where page_id = :'sod';

-- A new link: the server's to make. The old one stops.
update public.sop_shares set token = '22222222222222222222222222222222' where page_id = :'sod';
select tgs.check(public.guide_share_view(:'link', 'dana@example.com') is null and (public.guide_share_view('22222222222222222222222222222222', 'dana@example.com') ->> 'allowed') = 'true', 'a new link replaces the old one, for the same people');

-- A draft isn't shown, to anyone.
insert into public.sop_shares (page_id, company_id, token, access) values (:'draft', :'co', '33333333333333333333333333333333', 'anyone');
select tgs.check(public.guide_share_view('33333333333333333333333333333333') is null, 'a draft''s link shows nothing, even one for anyone');
update public.sop_pages set status = 'published' where id = :'draft';
select tgs.check((public.guide_share_view('33333333333333333333333333333333') ->> 'title') = 'Pricing notes', 'until it''s published');
update public.sop_pages set status = 'draft' where id = :'sod';
select tgs.check(public.guide_share_view('22222222222222222222222222222222', 'dana@example.com') is null, 'and a guide taken back to a draft stops showing');
update public.sop_pages set status = 'published' where id = :'sod';
commit;
reset role;

-- ===== Fifty people, and what goes with the guide ================================================
insert into public.sop_share_people (company_id, page_id, email)
select :'co', :'sod', 'person' || n || '@example.com' from generate_series(1, 48) n;
select tgs.expect_error(format('insert into public.sop_share_people (company_id, page_id, email) values (%L, %L, %L)', :'co', :'sod', 'onemore@example.com'), 'a guide is shared with up to 50 people');

delete from public.sop_pages where id = :'sod';
select tgs.check((select count(*) from public.sop_shares where page_id = :'sod') = 0 and (select count(*) from public.sop_share_people where page_id = :'sod') = 0, 'deleting a guide takes its link and its people with it');
select tgs.check(public.guide_share_view('22222222222222222222222222222222', 'dana@example.com') is null, 'and its link shows nothing');

\o
\echo guide_sharing_test.sql: all checks passed
