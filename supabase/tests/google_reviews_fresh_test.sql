-- Database tests for 20261113001860_google_reviews_kept_while_fresh.sql: the office reads only the
-- reviews the sync has seen in the last 29 days, and its numbers count only those; tidy_reviews
-- removes the copies that got old and only the server can run it; a copy removed for its age leaves
-- its client stopped from being asked again and its ask counted, and the office's match is taken
-- up when the review comes back in; a review removed any other way still lifts the stop; a review
-- Google says is gone loses its words, the reviewer's name and photo at once, however it's marked,
-- and gets them back if it returns; Google's own average and count are forgotten for a sync that
-- hasn't heard them in that long; and a notification about a review loses the reviewer's name and
-- words after the same time.
-- Run with scripts/test-db.sh (plain Postgres + prelude.sql). Any failed check stops with an error.
\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null

create schema tgrf;
grant usage on schema tgrf to authenticated, service_role;
-- A sequence counts the checks: it keeps counting through the rollback at the end.
create sequence tgrf.passed;
grant usage on sequence tgrf.passed to authenticated, service_role;
create function tgrf.check(p_ok boolean, p_what text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok, false) then raise exception 'FAIL: %', p_what; end if;
  perform nextval('tgrf.passed');
  raise notice 'ok - %', p_what;
end $$;
-- The error a statement raises, as "SQLSTATE: message" ('none' when it doesn't).
create function tgrf.error_of(p_sql text) returns text language plpgsql as $$
begin
  begin execute p_sql; exception when others then return sqlstate || ': ' || sqlerrm; end;
  return 'none';
end $$;
create function tgrf.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true)
$$;
-- A review as the server sends it to record_reviews.
create function tgrf.item(p_id text, p_name text, p_rating int, p_posted timestamptz, p_comment text default null) returns jsonb language sql as $$
  select jsonb_build_object('review_id', p_id, 'external_name', 'accounts/1/locations/9/reviews/' || p_id, 'reviewer_name', p_name,
    'reviewer_photo_url', 'https://lh3.googleusercontent.com/a/' || p_id, 'reviewer_anonymous', false, 'rating', p_rating,
    'comment', p_comment, 'posted_at', p_posted, 'google_updated_at', p_posted)
$$;
create function tgrf.review(p_company uuid, p_id text) returns public.reviews language sql as $$
  select * from public.reviews where company_id = p_company and review_id = p_id
$$;
-- The reviews someone signed in can read, by Google's ids.
create function tgrf.reads(p_company uuid) returns text language sql security invoker as $$
  select coalesce(string_agg(review_id, ',' order by review_id), '') from public.reviews where company_id = p_company
$$;
grant execute on all functions in schema tgrf to authenticated, service_role;

\set mia 'f6f00000-0000-0000-0000-000000000001'

-- Everything below is rolled back at the end, so every now() here is the same moment.
begin;
-- The tidy counts across every company: anything another test left behind is set aside first
-- (and comes back with the rollback), so the counts below are this test's own.
delete from public.reviews;
update public.review_syncs set average_rating = null, total_reviews = null;
delete from public.notifications where kind in ('review', 'review_low');
insert into auth.users (id, email, raw_user_meta_data) values (:'mia', 'mia@fresh.test', '{"full_name": "Mia Owner"}');
set local role authenticated;
select tgrf.as_user(:'mia');
select public.create_company('Fresh Lawn', 'lawn_care') as co \gset
insert into public.clients (company_id, display_name, email) values (:'co', 'Ana Smith', 'ana@example.test') returning id as ana \gset
insert into public.clients (company_id, display_name, email) values (:'co', 'Bob Jones', 'bob@example.test') returning id as bob \gset
insert into public.clients (company_id, display_name, email) values (:'co', 'Cy Hand', 'cy@example.test') returning id as cy \gset
reset role;
update public.companies set settings = settings || '{"marketing": {"enabled": true}}' where id = :'co';
insert into public.review_requests (company_id, client_id, channel, sent_at) values (:'co', :'ana', 'email', now() - interval '40 days') returning id as ana_ask \gset

set local role service_role;
select public.set_review_location(:'co', 'accounts/1', 'locations/9');
select public.claim_review_sync(:'co') as claim \gset
select public.record_reviews(:'co', :'claim', 'locations/9', jsonb_build_array(
  tgrf.item('r-ana', 'Ana S.', 5, now() - interval '35 days', 'Great job on the lawn!'),
  tgrf.item('r-bob', 'Bob Jones', 4, now() - interval '60 days', 'Tidy work.'),
  tgrf.item('r-hand', 'C. H.', 5, now() - interval '50 days', 'Would hire again.'),
  tgrf.item('r-new', 'Dee New', 5, now() - interval '1 day', 'Just what we wanted.'),
  tgrf.item('r-edge', 'Ed Edge', 3, now() - interval '90 days', 'Fine.')
));
select public.set_review_client(:'co', (tgrf.review(:'co', 'r-hand')).id, :'cy', :'mia');
update public.review_syncs set average_rating = 4.6, total_reviews = 5, last_synced_at = now(), full_synced_at = now() where company_id = :'co';
reset role;
select tgrf.check((tgrf.review(:'co', 'r-ana')).client_id = :'ana' and (tgrf.review(:'co', 'r-bob')).client_id = :'bob' and (tgrf.review(:'co', 'r-hand')).match = 'hand',
  'the reviews come in matched to their clients');
select tgrf.check((select reviewed_at is not null from public.clients where id = :'ana') and (select reviewed_at is not null from public.review_requests where id = :'ana_ask'),
  'which stops their asks and counts the ask that led to one');

\o
\echo 'The office reads only fresh reviews'
\o /dev/null
set local role authenticated;
select tgrf.as_user(:'mia');
select tgrf.check(tgrf.reads(:'co') = 'r-ana,r-bob,r-edge,r-hand,r-new', 'a review just seen is read');
reset role;
-- The sync stops seeing three of them (disconnected with the reviews kept, or a sign-in that stopped working).
update public.reviews set seen_at = now() - interval '29 days 1 minute' where company_id = :'co' and review_id in ('r-ana', 'r-bob', 'r-hand');
update public.reviews set seen_at = now() - interval '28 days 23 hours' where company_id = :'co' and review_id = 'r-edge';
set local role authenticated;
select tgrf.as_user(:'mia');
select tgrf.check(tgrf.reads(:'co') = 'r-edge,r-new', 'one the sync hasn''t seen for 29 days isn''t, before anything tidies it');
select tgrf.check((public.review_stats(:'co') ->> 'count')::int = 2, 'and the numbers count only the fresh ones');
select tgrf.check(tgrf.error_of('select public.tidy_reviews()') like '42501:%', 'the office can''t run the tidy');
reset role;

\o
\echo 'The tidy removes the copies that got old'
\o /dev/null
set local role service_role;
select public.tidy_reviews() as tidied \gset
reset role;
select tgrf.check(:'tidied'::jsonb = '{"removed": 3, "blanked": 0, "figures": 0, "notices": 0}', 'three old copies are removed');
select tgrf.check((select string_agg(review_id, ',' order by review_id) from public.reviews where company_id = :'co') = 'r-edge,r-new', 'and a copy a little under 29 days old stays');
select tgrf.check((select count(*) = 2 from public.clients where id in (:'ana', :'bob') and reviewed_at is not null), 'the clients who left them are still counted as having reviewed');
select tgrf.check((select reviewed_at is not null from public.review_requests where id = :'ana_ask'), 'the ask that led to one still counts');
select tgrf.check(public.begin_review_request(:'co', :'ana') is null, 'and nobody who already left a review is asked again');
select tgrf.check((select client_id = :'cy' from public.review_match_choices where company_id = :'co' and review_id = 'r-hand'), 'the office''s match is kept apart, as before');
set local role service_role;
select tgrf.check((public.tidy_reviews() ->> 'removed')::int = 0, 'a second run finds nothing more');

\o
\echo 'A review that comes back in'
\o /dev/null
-- Reconnected: the same reviews come in again.
select public.record_reviews(:'co', :'claim', 'locations/9', jsonb_build_array(
  tgrf.item('r-ana', 'Ana S.', 5, now() - interval '35 days', 'Great job on the lawn!'),
  tgrf.item('r-hand', 'C. H.', 5, now() - interval '50 days', 'Would hire again.')
)) as back \gset
reset role;
select tgrf.check(:'back' = '{new,new}', 'a removed copy comes in as new');
select tgrf.check((tgrf.review(:'co', 'r-hand')).client_id = :'cy' and (tgrf.review(:'co', 'r-hand')).match = 'hand', 'and takes up the match the office made');
select tgrf.check((tgrf.review(:'co', 'r-ana')).client_id = :'ana' and (tgrf.review(:'co', 'r-ana')).notify is null, 'an old review is matched again and isn''t news');
select tgrf.check((select reviewed_at = (tgrf.review(:'co', 'r-ana')).posted_at from public.clients where id = :'ana'), 'with the day it was posted on its client, as before');

\o
\echo 'A review taken off Google keeps no words'
\o /dev/null
update public.review_syncs set full_started_at = now() + interval '1 minute' where company_id = :'co';
set local role service_role;
select public.mark_deleted_reviews(:'co', :'claim', 'locations/9', array[(tgrf.review(:'co', 'r-ana')).id]) as marked \gset
reset role;
select tgrf.check((:'marked'::jsonb ->> 'marked')::int = 1 and :'marked'::jsonb -> 'lifted_clients' = jsonb_build_array(:'ana'), 'a review Google says is gone is marked, and its client can be asked again');
select tgrf.check((select deleted_at is not null and comment is null and reviewer_name is null and reviewer_photo_url is null and rating = 5 and review_id = 'r-ana'
  from public.reviews where company_id = :'co' and review_id = 'r-ana'), 'it loses its words, the reviewer''s name and photo at once, and keeps Google''s ids');
-- Marked by a reply Google answered with "no such review" (services/googleReviews.ts markGone): a plain update.
set local role service_role;
update public.reviews set deleted_at = now() where company_id = :'co' and review_id = 'r-new' and deleted_at is null;
update public.reviews set comment = 'put back', reviewer_name = 'Dee New' where company_id = :'co' and review_id = 'r-new';
reset role;
select tgrf.check((select comment is null and reviewer_name is null and reviewer_photo_url is null from public.reviews where company_id = :'co' and review_id = 'r-new'),
  'one marked any other way loses them too, and nothing puts them back while it''s gone');
set local role service_role;
select public.record_reviews(:'co', :'claim', 'locations/9', jsonb_build_array(tgrf.item('r-new', 'Dee New', 5, now() - interval '1 day', 'Just what we wanted.'))) as returned \gset
reset role;
select tgrf.check(:'returned' = '{changed}' and (select deleted_at is null and comment = 'Just what we wanted.' and reviewer_name = 'Dee New' and reviewer_photo_url is not null
  from public.reviews where company_id = :'co' and review_id = 'r-new'), 'a review that''s on Google again is written again whole');
-- One left from before this, with its words still there.
alter table public.reviews disable trigger review_gone_keeps_no_words;
update public.reviews set comment = 'Left from before', reviewer_name = 'Ana S.' where company_id = :'co' and review_id = 'r-ana';
alter table public.reviews enable trigger review_gone_keeps_no_words;
update public.reviews set seen_at = now() - interval '30 days' where company_id = :'co' and review_id = 'r-edge';
set local role service_role;
select public.tidy_reviews() as tidied \gset
reset role;
select tgrf.check(:'tidied'::jsonb = '{"removed": 1, "blanked": 1, "figures": 0, "notices": 0}', 'the tidy clears any gone review that still has words, and removes the next copy to get old');
select tgrf.check((select comment is null and reviewer_name is null from public.reviews where company_id = :'co' and review_id = 'r-ana'), 'so none is left');
update public.reviews set seen_at = now() - interval '30 days' where company_id = :'co' and review_id = 'r-ana';
set local role service_role;
select tgrf.check((public.tidy_reviews() ->> 'removed')::int = 1, 'a gone review''s row goes with the rest once it''s old');
reset role;

\o
\echo 'A review removed any other way still lifts its stop'
\o /dev/null
select tgrf.check((select reviewed_at is not null from public.clients where id = :'cy'), 'Cy is stopped by the review matched to him');
set local role service_role;
-- In the same transaction as a tidy: what the tidy switched off for its own removals is back on.
select public.end_review_sync(:'co', true) as ended \gset
reset role;
select tgrf.check((:'ended'::jsonb ->> 'removed')::int = 2 and :'ended'::jsonb -> 'lifted_clients' = jsonb_build_array(:'cy'), 'disconnecting with the reviews removed says whose stop it lifted');
select tgrf.check((select reviewed_at is null from public.clients where id = :'cy'), 'and lifts it');
select tgrf.check((select reviewed_at is not null from public.clients where id = :'bob'), 'a client whose copy only got old stays as he was');

\o
\echo 'Google''s own average and count'
\o /dev/null
set local role service_role;
select public.set_review_location(:'co', 'accounts/1', 'locations/9');
update public.review_syncs set average_rating = 4.6, total_reviews = 5, last_synced_at = now() - interval '28 days', locked_until = null where company_id = :'co';
select tgrf.check((public.tidy_reviews() ->> 'figures')::int = 0 and (select total_reviews = 5 from public.review_syncs where company_id = :'co'), 'figures heard in the last 29 days are kept');
update public.review_syncs set last_synced_at = now() - interval '30 days', locked_until = now() + interval '5 minutes' where company_id = :'co';
select tgrf.check((public.tidy_reviews() ->> 'figures')::int = 0, 'a sync that''s running now is left to finish');
update public.review_syncs set locked_until = null where company_id = :'co';
select tgrf.check((public.tidy_reviews() ->> 'figures')::int = 1, 'figures a sync hasn''t heard for that long are forgotten');
select tgrf.check((select average_rating is null and total_reviews is null from public.review_syncs where company_id = :'co'), 'both of them');
select tgrf.check((public.tidy_reviews() ->> 'figures')::int = 0, 'once');
reset role;

\o
\echo 'Notifications about a review'
\o /dev/null
insert into public.notifications (company_id, user_id, kind, title, body, link, created_at) values
  (:'co', :'mia', 'review', 'Dana Whitfield left a 5-star review', 'Great job on the lawn!', '/marketing?tab=reviews&review=1', now() - interval '30 days'),
  (:'co', :'mia', 'review_low', 'Cara L. changed their review to 2 stars', 'Missed a spot.', '/marketing?tab=reviews&review=2', now() - interval '45 days'),
  (:'co', :'mia', 'review', 'Sam left a review', null, '/marketing?tab=reviews&review=3', now() - interval '40 days'),
  (:'co', :'mia', 'review', 'Someone left a 4-star review', null, '/marketing?tab=reviews&review=4', now() - interval '40 days'),
  (:'co', :'mia', 'review', 'Dee New left a 5-star review', 'Just what we wanted.', '/marketing?tab=reviews&review=5', now() - interval '28 days'),
  (:'co', :'mia', 'review_access', 'Your Google reviews are in: 5 reviews, 4.6 average', 'See them, and reply, in Marketing → Reviews.', '/marketing?tab=reviews', now() - interval '60 days'),
  (:'co', :'mia', 'info', 'Dana Whitfield left a note', 'Gate code changed.', '/clients', now() - interval '60 days');
set local role service_role;
select tgrf.check((public.tidy_reviews() ->> 'notices')::int = 3, 'three notifications over 29 days old still named a reviewer or carried their words');
reset role;
select tgrf.check((select string_agg(title || coalesce(' | ' || body, ''), ' ; ' order by link) from public.notifications where company_id = :'co' and kind in ('review', 'review_low')) =
  'Someone left a 5-star review ; Someone changed their review to 2 stars ; Someone left a review ; Someone left a 4-star review ; Dee New left a 5-star review | Just what we wanted.',
  'they keep that a review came in, its stars and its link, and a newer one is left whole');
select tgrf.check((select count(*) = 2 from public.notifications where company_id = :'co' and kind in ('review_access', 'info') and body is not null and title not like 'Someone%'),
  'notifications about anything else are left alone');
set local role service_role;
select tgrf.check((public.tidy_reviews() ->> 'notices')::int = 0, 'and a second run changes nothing');
reset role;

rollback;

select last_value as passed from tgrf.passed \gset
set client_min_messages = warning;
drop schema tgrf cascade;
reset client_min_messages;

\o
\echo All :passed fresh Google review checks passed.
