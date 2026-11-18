-- How you compare: where "nearby" is isn't kept for more than 30 days.
--
-- review_comparisons.lat/lng is the company's address as a point on the map, found when the
-- comparison was turned on, to lean searches toward. When this server has a Google key that point
-- comes from Google's geocoder, and Google's Places API policies allow coordinates to be kept for
-- 30 days at most. It was kept for good.
--
--   review_comparisons.located_at   when the point was found.
--   expire_review_locations         forgets points found more than 30 days ago (and any with no
--                                   date). The review_compare task calls it hourly; the point is
--                                   found again the next time someone searches for a business
--                                   (apps/api/src/services/reviewCompare.ts).
--
-- Points already kept are dated by when their row last changed, so one kept longer than 30 days
-- goes at the first run. supabase/tests/review_comparison_test.sql covers it.

alter table public.review_comparisons add column located_at timestamptz;
comment on column public.review_comparisons.located_at is 'When lat and lng were found; they are forgotten 30 days later';
update public.review_comparisons set located_at = coalesce(updated_at, now()) where lat is not null and lng is not null;

create function public.expire_review_locations() returns integer
language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  update public.review_comparisons
     set lat = null, lng = null, located_at = null
   where (lat is not null or lng is not null)
     and (located_at is null or located_at < now() - interval '30 days');
  get diagnostics v_count = row_count;
  return v_count;
end $$;
revoke execute on function public.expire_review_locations() from public, anon, authenticated;
grant execute on function public.expire_review_locations() to service_role;

notify pgrst, 'reload schema';
