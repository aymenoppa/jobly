-- Database tests for 20261113001130_reviews_on_quotes.sql: "Show reviews on quotes" and the reviews
-- picked for them are saved together by the people who look after Marketing; three at most, only
-- this company's reviews still on Google, and the PDF tick only with the switch on.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema trq;
grant usage on schema trq to authenticated, service_role;
create function trq.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  raise notice 'ok - %', p_what;
end $$;
create function trq.error_of(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'none';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create function trq.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- A Google review of the company's location, as the sync brings it in.
create function trq.review(p_company uuid, p_id text, p_rating integer, p_deleted boolean default false) returns uuid language sql as $$
  insert into public.reviews (company_id, location_id, review_id, external_name, reviewer_name, rating, comment, posted_at, google_updated_at, deleted_at)
  values (p_company, 'locations/7', p_id, 'accounts/1/locations/7/reviews/' || p_id, 'Rev ' || p_id, p_rating, 'Words ' || p_id, now(), now(), case when p_deleted then now() end)
  returning id
$$;
-- The picks, in order, by their Google ids.
create function trq.picks(p_company uuid) returns text language sql stable as $$
  select string_agg(review_id, ',' order by quote_pick) from public.reviews where company_id = p_company and quote_pick is not null
$$;
grant execute on all functions in schema trq to authenticated, service_role;

\set rae 'a5c20000-0000-0000-0000-000000000001'
\set mo 'a5c20000-0000-0000-0000-000000000002'
\set cal 'a5c20000-0000-0000-0000-000000000003'
\set oz 'a5c20000-0000-0000-0000-000000000004'

begin;
insert into auth.users (id, email, raw_user_meta_data) values
  (:'rae', 'rae@ridge.test', '{"full_name": "Rae Ridge"}'), (:'mo', 'mo@ridge.test', '{"full_name": "Mo Office"}'),
  (:'cal', 'cal@ridge.test', '{"full_name": "Cal Crew"}'), (:'oz', 'oz@other.test', '{"full_name": "Oz Other"}');
set local role authenticated;
select trq.as_user(:'rae');
select public.create_company('Ridge Lawns', 'lawn') as co \gset
select trq.as_user(:'oz');
select public.create_company('Other Lawns', 'lawn') as other \gset
reset role;
insert into public.memberships (company_id, user_id, role) values (:'co', :'mo', 'office'), (:'co', :'cal', 'field_crew');
select trq.review(:'co', 'r1', 5) as r1 \gset
select trq.review(:'co', 'r2', 4) as r2 \gset
select trq.review(:'co', 'r3', 5) as r3 \gset
select trq.review(:'co', 'r4', 5) as r4 \gset
select trq.review(:'co', 'gone', 5, true) as gone \gset
select trq.review(:'other', 'theirs', 5) as theirs \gset

set local role authenticated;
select trq.as_user(:'mo');
select public.set_quote_reviews(:'co', true, true, array[:'r3', :'r1']::uuid[]) as saved \gset
reset role;
select trq.check((:'saved'::jsonb) = jsonb_build_object('show', true, 'pdf', true, 'picked', jsonb_build_array(:'r3', :'r1'))
  and (select settings -> 'quote_reviews' = '{"show": true, "pdf": true}' from public.companies where id = :'co') and trq.picks(:'co') = 'r3,r1',
  'the office with the marketing area turns it on for the Client Hub and the PDF, and picks two reviews in order');

set local role authenticated;
select trq.as_user(:'mo');
select public.set_quote_reviews(:'co', true, true, array[:'r2']::uuid[]);
reset role;
select trq.check(trq.picks(:'co') = 'r2', 'picking again replaces the picks');

set local role authenticated;
select trq.as_user(:'mo');
select trq.check(trq.error_of(format('select public.set_quote_reviews(%L, true, false, %L::uuid[])', :'co', array[:'r1', :'r2', :'r3', :'r4'])) = '22023: Pick up to three reviews.',
  'three at most');
select trq.check(trq.error_of(format('select public.set_quote_reviews(%L, true, false, %L::uuid[])', :'co', array[:'gone'])) = '22023: That review isn''t on Google anymore. Pick another.'
  and trq.error_of(format('select public.set_quote_reviews(%L, true, false, %L::uuid[])', :'co', array[:'theirs'])) = '22023: That review isn''t on Google anymore. Pick another.'
  and trq.error_of(format('select public.set_quote_reviews(%L, true, false, %L::uuid[])', :'co', array[:'r1', :'r1'])) = '22023: That review isn''t on Google anymore. Pick another.',
  'only this company''s reviews still on Google, each once');
select public.set_quote_reviews(:'co', false, true, '{}');
reset role;
select trq.check((select settings -> 'quote_reviews' = '{"show": false, "pdf": false}' from public.companies where id = :'co') and trq.picks(:'co') is null,
  'turned off, the PDF tick goes with it, and no picks are left');

set local role authenticated;
select trq.as_user(:'cal');
select trq.check(trq.error_of(format('select public.set_quote_reviews(%L, true, false, ''{}'')', :'co')) = '42501: Only the people who look after Marketing can change this.',
  'the crew can''t change it');
select trq.as_user(:'oz');
select trq.check(trq.error_of(format('select public.set_quote_reviews(%L, true, false, ''{}'')', :'co')) like '42501:%', 'nor another business''s owner');
reset role;
select trq.check((select settings -> 'quote_reviews' = '{"show": false, "pdf": false}' from public.companies where id = :'co'), 'and nothing changed');
rollback;

\echo 'All reviews on quotes tests passed.'
