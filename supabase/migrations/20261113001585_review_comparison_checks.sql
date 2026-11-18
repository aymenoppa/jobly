-- How you compare: "since last week" that survives being checked twice.
--
-- Each place keeps its review count as last checked and one count from before, to say how it
-- changed. Every check used to move the last count into "before", so two servers running the weekly
-- check in the same minute, or a "Check now" the day after it, left the card comparing a count with
-- itself: "No change" everywhere.
--
--   record_review_place      the count kept from before is now one from at least six days back:
--                            the last count takes its place only once it's that old (or when
--                            there's nothing from before yet). A second check soon after the first
--                            changes the latest numbers and leaves the comparison alone.
--   review_comparisons.tried_at, claim_review_comparisons
--                            the weekly check claims each company as it takes it, so two servers
--                            don't both ask Google; a check that failed is tried again the next
--                            day, not the next hour and not the next week. checked_at is now only
--                            when a check last worked, so a failed one doesn't make "Check now"
--                            wait a day (apps/api/src/services/reviewCompare.ts).
--   review_places.problem    what's wrong with one place (Google doesn't list it anymore, or says
--                            it's permanently closed), so it can be named and skipped without
--                            stopping the others.
--
-- supabase/tests/review_comparison_test.sql covers it.

alter table public.review_comparisons add column tried_at timestamptz;
comment on column public.review_comparisons.tried_at is 'When the weekly check last took this company, whether or not Google answered';
alter table public.review_places add column problem text check (length(problem) <= 300);
comment on column public.review_places.problem is 'Why the last check skipped this place (not listed on Google anymore, or closed); null when it was read';

-- From 20261113001420_review_comparison.sql, with the comparison kept from at least six days back.
create or replace function public.record_review_place(p_id uuid, p_name text, p_rating numeric, p_total integer, p_maps_url text default null)
returns void language sql security definer set search_path = '' as $$
  update public.review_places
     set name = coalesce(nullif(left(trim(p_name), 300), ''), name),
         maps_url = coalesce(case when p_maps_url ~ '^https://' then p_maps_url end, maps_url),
         previous_total = case
           when checked_at is null then previous_total
           when previous_checked_at is null or checked_at <= now() - interval '6 days' then ratings_total
           else previous_total end,
         previous_checked_at = case
           when checked_at is null then previous_checked_at
           when previous_checked_at is null or checked_at <= now() - interval '6 days' then checked_at
           else previous_checked_at end,
         rating = least(greatest(p_rating, 0), 5), ratings_total = greatest(p_total, 0), checked_at = now(), problem = null
   where id = p_id
$$;

-- The companies whose weekly check is due, claimed as they're handed out: turned on, Marketing
-- installed, no check that worked in 7 days, and not tried in the last day.
create function public.claim_review_comparisons(p_limit integer default 20)
returns table (company_id uuid) language sql security definer set search_path = '' as $$
  update public.review_comparisons r
     set tried_at = now()
   where r.company_id in (
     select x.company_id
       from public.review_comparisons x
       join public.companies c on c.id = x.company_id
      where x.enabled and c.settings -> 'marketing' ->> 'enabled' = 'true'
        and (x.checked_at is null or x.checked_at < now() - interval '7 days')
        and (x.tried_at is null or x.tried_at < now() - interval '1 day')
        and exists (select 1 from public.review_places p where p.company_id = x.company_id)
      order by x.checked_at nulls first
      limit least(greatest(coalesce(p_limit, 20), 1), 100)
      for update of x skip locked)
  returning r.company_id
$$;
revoke execute on function public.claim_review_comparisons(integer) from public, anon, authenticated;
grant execute on function public.claim_review_comparisons(integer) to service_role;

notify pgrst, 'reload schema';
