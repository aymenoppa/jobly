-- "Show reviews on quotes": the quote in the Client Hub (and, with a second tick, its PDF) shows the
-- business's Google rating and how many reviews it has, and up to three reviews: the ones the office
-- picks in Marketing → Reviews, else the three newest with 5 stars and words. Only Google reviews
-- brought in by Google Business Profile (public.reviews, which holds nothing else: a client's private
-- answer to a review request never reaches it) that are still on Google (deleted_at null), of the
-- location being synced. Nothing shows without any. The server picks and trims them
-- (routes/public.ts, core reviews.ts quoteReviews); this keeps the switch and the picks.
--
--   settings.quote_reviews   {show, pdf}, off unless set
--   reviews.quote_pick       1 to 3, the order the office picked them in; null for the rest
--
-- set_quote_reviews writes both, for the people who see Marketing → Reviews.
-- supabase/tests/reviews_on_quotes_test.sql covers it.

alter table public.reviews add column quote_pick smallint check (quote_pick between 1 and 3);
comment on column public.reviews.quote_pick is 'Picked to show on quotes (settings.quote_reviews), in this order; null when it isn''t. Written by set_quote_reviews.';
create unique index reviews_quote_pick_idx on public.reviews (company_id, quote_pick) where quote_pick is not null;

/**
 * Show reviews on quotes, on its PDF too, and which (up to three, in order; none: the newest 5-star
 * ones with words). Owners, admins and office staff with the marketing area, as Marketing → Reviews.
 * Says {show, pdf, picked}.
 */
create function public.set_quote_reviews(p_company uuid, p_show boolean, p_pdf boolean, p_ids uuid[] default '{}') returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[] := coalesce(p_ids, '{}');
begin
  if not private.has_role(p_company, '{owner,admin,office}') or not private.has_perm(p_company, 'marketing') then
    raise exception 'Only the people who look after Marketing can change this.' using errcode = '42501';
  end if;
  if cardinality(v_ids) > 3 then
    raise exception 'Pick up to three reviews.' using errcode = '22023';
  end if;
  if cardinality(v_ids) <> (select count(distinct x) from unnest(v_ids) x)
     or exists (select 1 from unnest(v_ids) x where not exists (
       select 1 from public.reviews r where r.id = x and r.company_id = p_company and r.deleted_at is null)) then
    raise exception 'That review isn''t on Google anymore. Pick another.' using errcode = '22023';
  end if;
  update public.companies c
     set settings = jsonb_set(coalesce(c.settings, '{}'), '{quote_reviews}',
                              jsonb_build_object('show', coalesce(p_show, false), 'pdf', coalesce(p_show, false) and coalesce(p_pdf, false)))
   where c.id = p_company;
  update public.reviews set quote_pick = null where company_id = p_company and quote_pick is not null;
  update public.reviews r set quote_pick = x.n
    from unnest(v_ids) with ordinality x (id, n)
   where r.id = x.id and r.company_id = p_company;
  return jsonb_build_object('show', coalesce(p_show, false), 'pdf', coalesce(p_show, false) and coalesce(p_pdf, false), 'picked', to_jsonb(v_ids));
end $$;
revoke execute on function public.set_quote_reviews(uuid, boolean, boolean, uuid[]) from public, anon;
grant execute on function public.set_quote_reviews(uuid, boolean, boolean, uuid[]) to authenticated, service_role;

notify pgrst, 'reload schema';
