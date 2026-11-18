-- Postcards: only an address Lob will take counts as mailable, so the number shown before Send is
-- the number mailed.
--
-- Lob takes a US state as two letters and a ZIP as 12345 or 12345-6789 (docs.lob.com, Postcards →
-- Create: address_state ^[a-zA-Z]{2}$, address_zip ^\d{5}(-\d{4})?$), a street line of at most 64
-- characters and a city of at most 200. The app's State box takes anything, so until now a client
-- in "Illinois" was counted in "N clients will get a card" and then refused by Lob card by card.
--
--   private.us_state_code     a state as typed ("IL", "il", "Illinois", "D.C.") as its two-letter
--                             code, or null when it isn't a US state.
--   private.mailable_address  now gives the state as its code and the ZIP as Lob takes it
--                             ("627011234" becomes "62701-1234"), and says why an address can't be
--                             mailed to in two more ways: bad_state (not a US state) and too_long
--                             (a line longer than Lob takes).
--   private.mailing_address   when none of a client's addresses can be mailed to, says the problem
--                             most worth fixing: bad_state, then too_long, outside_us, no_address.
--   postcard_audience_summary counts the two new reasons.
--
-- packages/core/src/postcards.ts (mailable, usStateCode) reads addresses the same way.
-- supabase/tests/postcard_fixes_test.sql covers it.

create function private.us_state_code(p_state text) returns text
language sql immutable set search_path = '' as $$
  with typed as (
    select lower(trim(regexp_replace(replace(coalesce(p_state, ''), '.', ''), '\s+', ' ', 'g'))) as v
  )
  select coalesce(
    (select upper(t.v) from typed t
      where upper(t.v) in ('AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN',
                           'MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA',
                           'WV','WI','WY','AS','GU','MP','PR','VI','AA','AE','AP')),
    (select s.code from typed t join (values
      ('alabama','AL'),('alaska','AK'),('arizona','AZ'),('arkansas','AR'),('california','CA'),('colorado','CO'),('connecticut','CT'),
      ('delaware','DE'),('district of columbia','DC'),('florida','FL'),('georgia','GA'),('hawaii','HI'),('idaho','ID'),('illinois','IL'),
      ('indiana','IN'),('iowa','IA'),('kansas','KS'),('kentucky','KY'),('louisiana','LA'),('maine','ME'),('maryland','MD'),
      ('massachusetts','MA'),('michigan','MI'),('minnesota','MN'),('mississippi','MS'),('missouri','MO'),('montana','MT'),('nebraska','NE'),
      ('nevada','NV'),('new hampshire','NH'),('new jersey','NJ'),('new mexico','NM'),('new york','NY'),('north carolina','NC'),
      ('north dakota','ND'),('ohio','OH'),('oklahoma','OK'),('oregon','OR'),('pennsylvania','PA'),('rhode island','RI'),
      ('south carolina','SC'),('south dakota','SD'),('tennessee','TN'),('texas','TX'),('utah','UT'),('vermont','VT'),('virginia','VA'),
      ('washington','WA'),('west virginia','WV'),('wisconsin','WI'),('wyoming','WY'),
      ('american samoa','AS'),('guam','GU'),('northern mariana islands','MP'),('puerto rico','PR'),('virgin islands','VI'),
      ('armed forces americas','AA'),('armed forces europe','AE'),('armed forces pacific','AP'),
      ('washington dc','DC'),('washington, dc','DC'),('us virgin islands','VI'),('u s virgin islands','VI')
    ) s(name, code) on s.name = t.v))
$$;
revoke all on function private.us_state_code(text) from public;
grant execute on function private.us_state_code(text) to authenticated, service_role;

-- From 20261113001400_postcards.sql, with the state as its code, the ZIP as Lob takes it, and the
-- two new reasons. The address as Lob gets it, or {"problem": "no_address" | "outside_us" |
-- "bad_state" | "too_long"}.
create or replace function private.mailable_address(p_line1 text, p_line2 text, p_city text, p_region text, p_zip text, p_country text) returns jsonb
language sql immutable set search_path = '' as $$
  with a as (
    select regexp_replace(trim(coalesce(p_line1, '')), '\s+', ' ', 'g') as line1,
           regexp_replace(trim(coalesce(p_line2, '')), '\s+', ' ', 'g') as line2,
           regexp_replace(trim(coalesce(p_city, '')), '\s+', ' ', 'g') as city,
           regexp_replace(trim(coalesce(p_region, '')), '\s+', ' ', 'g') as region,
           regexp_replace(trim(coalesce(p_zip, '')), '\s+', ' ', 'g') as zip
  )
  select case
    when a.line1 = '' or a.city = '' or a.region = '' or a.zip = ''
      then jsonb_build_object('problem', 'no_address')
    when lower(trim(coalesce(p_country, ''))) not in ('', 'us', 'usa', 'u.s.', 'u.s.a.', 'united states', 'united states of america')
         or a.zip !~ '^\d{5}([- ]?\d{4})?$'
      then jsonb_build_object('problem', 'outside_us')
    when private.us_state_code(a.region) is null
      then jsonb_build_object('problem', 'bad_state')
    when length(a.line1) > 64 or length(a.line2) > 64 or length(a.city) > 200
      then jsonb_build_object('problem', 'too_long')
    else jsonb_strip_nulls(jsonb_build_object(
      'line1', a.line1, 'line2', nullif(a.line2, ''), 'city', a.city, 'region', private.us_state_code(a.region),
      'postal_code', case when length(a.zip) = 5 then a.zip else left(a.zip, 5) || '-' || right(a.zip, 4) end, 'country', 'US'))
  end
  from a
$$;

-- From 20261113001400_postcards.sql: the first address that can be mailed to, billing first, else
-- why none can, the problem most worth fixing first.
create or replace function private.mailing_address(c public.clients) returns jsonb
language sql stable security invoker set search_path = '' as $$
  with tries as (
    select 0 as n, private.mailable_address(c.billing_address ->> 'line1', c.billing_address ->> 'line2', c.billing_address ->> 'city',
             coalesce(nullif(c.billing_address ->> 'region', ''), c.billing_address ->> 'state'), c.billing_address ->> 'postal_code', c.billing_address ->> 'country') as a
    union all
    select row_number() over (order by p.created_at, p.id), private.mailable_address(p.line1, p.line2, p.city, p.region, p.postal_code, p.country)
      from public.properties p where p.client_id = c.id and p.company_id = c.company_id
  )
  select coalesce(
    (select a from tries where not a ? 'problem' order by n limit 1),
    (select a from tries where a ->> 'problem' = 'bad_state' limit 1),
    (select a from tries where a ->> 'problem' = 'too_long' limit 1),
    (select a from tries where a ->> 'problem' = 'outside_us' limit 1),
    jsonb_build_object('problem', 'no_address'))
$$;

-- From 20261113001400_postcards.sql, counting the two new reasons too.
create or replace function public.postcard_audience_summary(p_company uuid, p_audience jsonb) returns jsonb
language sql stable security invoker set search_path = '' as $$
  with a as (select * from public.postcard_audience(p_company, p_audience))
  select jsonb_build_object(
    'count', (select count(*) from a where left_out is null),
    'left_out', jsonb_build_object(
      'archived', (select count(*) from a where left_out = 'archived'),
      'opted_out', (select count(*) from a where left_out = 'opted_out'),
      'no_address', (select count(*) from a where left_out = 'no_address'),
      'outside_us', (select count(*) from a where left_out = 'outside_us'),
      'bad_state', (select count(*) from a where left_out = 'bad_state'),
      'too_long', (select count(*) from a where left_out = 'too_long')),
    'sample', coalesce((select jsonb_agg(jsonb_build_object('client_id', s.client_id, 'name', s.display_name, 'city', s.address ->> 'city', 'region', s.address ->> 'region'))
                          from (select * from a where left_out is null limit 5) s), '[]'::jsonb))
$$;

notify pgrst, 'reload schema';
