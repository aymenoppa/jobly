-- Google reviews are a copy of what's on Google, kept only while the sync keeps seeing it there.
--
--   Fresh                    a review the sync has seen in the last 29 days (reviews.seen_at; every
--                            pass that reads a review from Google says so, and a full pass reads them
--                            all once a day). 29, so a tidy that runs once a day never leaves a copy
--                            past 30. packages/core/src/reviews.ts REVIEW_FRESH_DAYS is the same number.
--   reviews_fresh            people signed in read only fresh reviews: Marketing → Reviews, its
--                            numbers (review_stats reads as the person asking) and everything else
--                            that reads the table from the browser. The server asks for fresh ones
--                            itself wherever it shows or reuses one (quotes, review cards).
--   tidy_reviews             the review_tidy task, once a day: removes the copies that aren't fresh
--                            anymore, whatever the reason (disconnected with the reviews kept, a
--                            sign-in that stopped working, Google's approval taken away), and forgets
--                            Google's average and count for a sync that hasn't heard them in that long.
--                            A notification about a review keeps the reviewer's name and the start
--                            of their words for the same 29 days, then only says a review came in.
--   Taken off Google         a review marked deleted keeps no words, reviewer name or photo link from
--                            that moment (review_gone_keeps_no_words), and the ones marked before
--                            this lose theirs here. Its row goes with the rest once it isn't fresh.
--
-- A copy removed because it got old isn't a review taken down. The office's match or "Not this
-- client" is kept apart already (review_match_choices) and taken up again when the review comes
-- back in. What the review said about its client stays too: clients.reviewed_at and the ask it
-- answered are left as they were, so nobody who already left a review is asked again because a
-- sync stopped. Picks for quotes (reviews.quote_pick) go with the rows.
-- supabase/tests/google_reviews_fresh_test.sql covers it.

-- As in 20261031000300_google_reviews.sql, and a copy that tidy_reviews removes for its age leaves
-- its client's reviewed_at and its ask's reviewed_at alone.
create or replace function private.reviews_client_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_clients uuid[] := array_remove(array[
    case when tg_op <> 'INSERT' then old.client_id end,
    case when tg_op <> 'DELETE' then new.client_id end], null);
  v_old_request uuid := case when tg_op <> 'INSERT' then old.review_request_id end;
  v_new_request uuid := case when tg_op <> 'DELETE' and new.deleted_at is null then new.review_request_id end;
begin
  if tg_op = 'DELETE' and coalesce(current_setting('jobly.review_tidy', true), '') = 'on' then
    return null;
  end if;
  if cardinality(v_clients) > 0 then
    perform set_config('jobly.reviewed', 'on', true);
    update public.clients c
       set reviewed_at = x.first
      from (select cl.id,
                   (select min(r.posted_at) from public.reviews r
                     where r.company_id = cl.company_id and r.client_id = cl.id and r.deleted_at is null) as first
              from public.clients cl where cl.id = any (v_clients)) x
     where c.id = x.id and c.reviewed_at is distinct from x.first;
    perform set_config('jobly.reviewed', '', true);
  end if;
  if v_old_request is not null and v_old_request is distinct from v_new_request then
    update public.review_requests q set reviewed_at = null
     where q.id = v_old_request and q.reviewed_at is not null
       and not exists (select 1 from public.reviews r where r.review_request_id = v_old_request and r.deleted_at is null and r.id <> old.id);
  end if;
  if v_new_request is not null then
    update public.review_requests q set reviewed_at = new.posted_at
     where q.id = v_new_request and q.reviewed_at is distinct from new.posted_at;
  end if;
  return null;
end $$;

-- A review Google says is gone keeps nothing the reviewer wrote or who they are, however it was
-- marked (mark_deleted_reviews, or a reply Google answered with "no such review"). One that comes
-- back is written again whole by record_reviews, which clears deleted_at.
create function private.review_gone_keeps_no_words() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.comment := null;
  new.reviewer_name := null;
  new.reviewer_photo_url := null;
  return new;
end $$;
create trigger review_gone_keeps_no_words before insert or update on public.reviews
  for each row when (new.deleted_at is not null) execute function private.review_gone_keeps_no_words();

-- The ones marked before this.
update public.reviews set comment = null, reviewer_name = null, reviewer_photo_url = null
 where deleted_at is not null and (comment is not null or reviewer_name is not null or reviewer_photo_url is not null);

-- People signed in read only the reviews the sync has seen lately. With reviews_read and the
-- marketing area's own policy: this one only ever narrows. (No index on seen_at: every pass
-- rewrites it on every review, and the tidy reads the table once a day.)
create policy reviews_fresh on public.reviews as restrictive for select to authenticated
  using (seen_at > now() - interval '29 days');

-- The review_tidy task (apps/api/src/services/googleReviews.ts tidyReviews), once a day. Says how
-- many copies it removed, how many gone reviews still had words to lose (none, once the trigger
-- above is in), how many syncs' Google figures it forgot, and how many notifications about a
-- review it took the reviewer's name and words out of.
create function public.tidy_reviews() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_removed integer;
  v_blanked integer;
  v_figures integer;
  v_notices integer;
begin
  perform set_config('jobly.review_tidy', 'on', true);
  delete from public.reviews where seen_at <= now() - interval '29 days';
  get diagnostics v_removed = row_count;
  perform set_config('jobly.review_tidy', '', true);

  update public.reviews set comment = null, reviewer_name = null, reviewer_photo_url = null
   where deleted_at is not null and (comment is not null or reviewer_name is not null or reviewer_photo_url is not null);
  get diagnostics v_blanked = row_count;

  update public.review_syncs set average_rating = null, total_reviews = null
   where (average_rating is not null or total_reviews is not null)
     and coalesce(last_synced_at, '-infinity') <= now() - interval '29 days'
     and (locked_until is null or locked_until < now());
  get diagnostics v_figures = row_count;

  -- The office's notifications about a review carry the reviewer's name and the start of their
  -- words (claim_review_notices). After the same 29 days one keeps only that a review came in, its
  -- stars and its link: "Someone left a 5-star review", the words an anonymous one always had.
  update public.notifications n
     set title = regexp_replace(n.title, '^.* (left a |changed their review to )', 'Someone \1'), body = null
   where n.kind in ('review', 'review_low') and n.created_at <= now() - interval '29 days'
     and (n.body is not null or n.title !~ '^Someone (left a |changed their review to )');
  get diagnostics v_notices = row_count;
  return jsonb_build_object('removed', v_removed, 'blanked', v_blanked, 'figures', v_figures, 'notices', v_notices);
end $$;

revoke all on function private.review_gone_keeps_no_words() from public;
revoke execute on function public.tidy_reviews() from public, anon, authenticated;
grant execute on function public.tidy_reviews() to service_role;

notify pgrst, 'reload schema';
