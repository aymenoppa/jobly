-- How you compare (Marketing → Reviews): only place IDs are kept.
--
-- Google's Places API policies (developers.google.com/maps/documentation/places/web-service/policies,
-- "Data storage, caching, and scraping" and "Exceptions from caching restrictions") let an
-- application keep a place's ID for good and nothing else about it: not its name, address, Maps
-- link, rating or number of reviews. The card kept all of those, the count from the week before and
-- when each was read, and the company's address as a point on the map, and a weekly task kept them
-- up to date from the server.
--
-- Now the browser reads each place from Google when someone presses Compare now, shows it, and
-- keeps nothing (apps/web/src/features/marketing/ReviewCompare.tsx). What's left here:
--
--   review_comparisons   company_id, enabled (the switch, off until an owner or admin turns it on),
--                        enabled_by, updated_at.
--   review_places        id, company_id, place_id (Google's ID for the place), is_own (the business
--                        itself, one at most), created_at. Up to five competitors, as before.
--
-- Everything else goes, with what was saved in it: the columns, the functions that kept them
-- (record_review_place, review_comparisons_due, claim_review_comparisons, expire_review_locations)
-- and, in the server, the review_compare task. Nothing released reads any of it. Row-level security
-- is as it was: read by the office with the marketing area, written only by the server.
-- supabase/tests/review_comparison_test.sql covers it.

drop function if exists public.record_review_place(uuid, text, numeric, integer, text);
drop function if exists public.review_comparisons_due(integer);
drop function if exists public.claim_review_comparisons(integer);
drop function if exists public.expire_review_locations();

alter table public.review_comparisons
  drop column if exists lat,
  drop column if exists lng,
  drop column if exists located_at,
  drop column if exists checked_at,
  drop column if exists checked_by_hand_at,
  drop column if exists tried_at,
  drop column if exists last_error;

alter table public.review_places
  drop column if exists name,
  drop column if exists address,
  drop column if exists maps_url,
  drop column if exists rating,
  drop column if exists ratings_total,
  drop column if exists previous_total,
  drop column if exists checked_at,
  drop column if exists previous_checked_at,
  drop column if exists problem;

-- place_id holds a Google place ID and nothing that reads like one of the fields above: letters,
-- digits, hyphens and underscores only, so an address, a link or a sentence can't be kept in its place.
delete from public.review_places where place_id !~ '^[A-Za-z0-9_-]+$';
alter table public.review_places add constraint review_places_place_id_shape check (place_id ~ '^[A-Za-z0-9_-]+$');

-- A dropped column's values stay inside each row on disk until the table is next rewritten, and
-- tables this small are never vacuumed by themselves. So both are rewritten here: changing a
-- column's type through an expression makes Postgres copy every row into a new file, without the
-- dropped columns' values, and delete the old file when this migration commits. The types and the
-- values stay what they were.
alter table public.review_places alter column place_id type text using (place_id || '');
alter table public.review_comparisons alter column enabled type boolean using (enabled is true);

comment on table public.review_comparisons is 'Whether a company compares its Google reviews with competitors''. Nothing from Google is kept here';
comment on table public.review_places is 'The Google place IDs of the business itself and up to five competitors. Only the ID: Google''s terms allow nothing else about a place to be kept';
comment on column public.review_places.place_id is 'Google''s ID for the place, which its terms allow to be kept. Its name, rating and the rest are read from Google in the browser and never saved';

notify pgrst, 'reload schema';
