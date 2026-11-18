-- How you compare (Marketing → Reviews): the business's Google rating and number of reviews next to
-- up to five nearby competitors', and how each count changed since the check before
-- (apps/api/src/services/reviewCompare.ts, through Google Places).
--
--   review_comparisons   the company's switch (off until an owner or admin turns it on, and only
--                        after Google answers with the key it will use), where "nearby" is, when it
--                        was last checked (at most weekly by the review_compare task, by hand at most
--                        once a day) and the last problem.
--   review_places        the business's own place and the competitors picked, each with its rating
--                        and review count as last checked and the count the check before, so the
--                        card shows them at once without asking Google.
--
-- Both are read by the office with the marketing area and written only by the server, which keeps
-- the calls to Google few: one Place Details per place per check, with only the fields it shows.
-- supabase/tests/review_comparison_test.sql covers it.

create table public.review_comparisons (
  company_id uuid primary key references public.companies (id) on delete cascade,
  enabled boolean not null default false,
  -- Where suggestions and searches lean: the company's address, as geocoded when it was turned on.
  lat double precision check (lat between -90 and 90),
  lng double precision check (lng between -180 and 180),
  checked_at timestamptz,
  checked_by_hand_at timestamptz,
  last_error text check (length(last_error) <= 500),
  enabled_by uuid references auth.users (id) on delete set null,
  updated_at timestamptz not null default now()
);
comment on table public.review_comparisons is 'Whether a company compares its Google reviews with competitors'', and when they were checked';

create table public.review_places (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  place_id text not null check (length(place_id) between 1 and 300),
  name text not null check (length(name) between 1 and 300),
  address text check (length(address) <= 500),
  maps_url text check (maps_url is null or maps_url ~ '^https://'),
  is_own boolean not null default false,
  rating numeric(2, 1) check (rating between 0 and 5),
  ratings_total integer check (ratings_total >= 0),
  previous_total integer check (previous_total >= 0),
  checked_at timestamptz,
  previous_checked_at timestamptz,
  created_at timestamptz not null default now(),
  unique (company_id, place_id)
);
create unique index review_places_own_idx on public.review_places (company_id) where is_own;
create index review_places_company_idx on public.review_places (company_id, created_at);
comment on table public.review_places is 'The business''s own Google place and up to five competitors'', with their ratings as last checked';

-- Up to five competitors, besides the business itself.
create function private.review_places_limit() returns trigger
language plpgsql set search_path = '' as $$
begin
  if not new.is_own and (select count(*) from public.review_places p where p.company_id = new.company_id and not p.is_own and p.id <> new.id) >= 5 then
    raise exception 'Compare with up to five competitors. Remove one first.' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function private.review_places_limit() from public;
create trigger review_places_limit before insert or update of is_own on public.review_places
  for each row execute function private.review_places_limit();

select private.add_touch_triggers(array['review_comparisons']);
alter table public.review_comparisons enable row level security;
alter table public.review_places enable row level security;
create policy review_comparisons_read on public.review_comparisons for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}'));
create policy review_places_read on public.review_places for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}'));
select private.restrict_area('review_comparisons', 'marketing', true);
select private.restrict_area('review_places', 'marketing', true);
revoke all on public.review_comparisons, public.review_places from anon;
revoke insert, update, delete, truncate on public.review_comparisons, public.review_places from authenticated;

-- A check's results for one place: the count before becomes the previous one, so the card can say
-- how it changed. Only the server calls it.
create function public.record_review_place(p_id uuid, p_name text, p_rating numeric, p_total integer, p_maps_url text default null)
returns void language sql security definer set search_path = '' as $$
  update public.review_places
     set name = coalesce(nullif(left(trim(p_name), 300), ''), name),
         maps_url = coalesce(case when p_maps_url ~ '^https://' then p_maps_url end, maps_url),
         previous_total = case when checked_at is null then previous_total else ratings_total end,
         previous_checked_at = case when checked_at is null then previous_checked_at else checked_at end,
         rating = least(greatest(p_rating, 0), 5), ratings_total = greatest(p_total, 0), checked_at = now()
   where id = p_id
$$;
revoke execute on function public.record_review_place(uuid, text, numeric, integer, text) from public, anon, authenticated;
grant execute on function public.record_review_place(uuid, text, numeric, integer, text) to service_role;

-- The companies whose weekly check is due: turned on, Marketing installed, not checked for 7 days.
create function public.review_comparisons_due(p_limit integer default 20)
returns table (company_id uuid) language sql stable security definer set search_path = '' as $$
  select r.company_id
    from public.review_comparisons r
    join public.companies c on c.id = r.company_id
   where r.enabled and c.settings -> 'marketing' ->> 'enabled' = 'true'
     and (r.checked_at is null or r.checked_at < now() - interval '7 days')
     and exists (select 1 from public.review_places p where p.company_id = r.company_id)
   order by r.checked_at nulls first
   limit least(greatest(coalesce(p_limit, 20), 1), 100)
$$;
revoke execute on function public.review_comparisons_due(integer) from public, anon, authenticated;
grant execute on function public.review_comparisons_due(integer) to service_role;

select private.fold_member_checks('public.review_comparisons');
select private.fold_member_checks('public.review_places');

notify pgrst, 'reload schema';
