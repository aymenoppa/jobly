-- Where a property's spot on the map came from, kept with the spot.
--
--   properties.located_by    'census' or 'openstreetmap': the free geocoder that found the address
--                            (apps/api/src/services/external.ts lookUpAddress); 'unknown': a spot
--                            from before this was kept that neither of them has the address for, left
--                            as it was; null: nobody has said (or there's no spot).
--   settings.depot.source    the same for the shop, beside its lat and lng.
--
-- The server says where from whenever it saves a spot (services/properties.ts saveLocation). A spot
-- saved by anything that doesn't say (a server from before this update, still running while the
-- update goes in) is left as "nobody has said". On a server that has a Google server key, the pins
-- task (services/properties.ts relocatePins) looks each of those up again with the free geocoders,
-- a few at a time, and saves what they say: depots_to_relocate and relocate_depot are its part for
-- the shop. A server with no such key leaves them alone.
-- supabase/tests/map_spot_sources_test.sql covers it.

alter table public.properties add column located_by text check (located_by in ('census', 'openstreetmap', 'unknown'));
comment on column public.properties.located_by is 'Where lat and lng came from: the census or openstreetmap geocoder, unknown (from before this was kept, and neither has the address), or null when nobody has said';

-- No spot, no source. And a spot that moves without its source being said again was saved by
-- something that doesn't say, so its source isn't known anymore. (A spot the same geocoder moves is
-- said again by the server, in a second write.)
create function private.property_located_by() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.lat is null or new.lng is null then
    new.located_by := null;
  elsif tg_op = 'UPDATE' and (new.lat is distinct from old.lat or new.lng is distinct from old.lng)
        and new.located_by is not distinct from old.located_by then
    new.located_by := null;
  end if;
  return new;
end $$;
create trigger property_located_by before insert or update of lat, lng, located_by on public.properties
  for each row execute function private.property_located_by();

-- The shops whose spot has no source yet, each with the company's address as it is now.
create function public.depots_to_relocate(p_limit integer default 20)
returns table (company_id uuid, address jsonb, depot jsonb)
language sql stable security definer set search_path = '' as $$
  select c.id, c.address, c.settings -> 'depot'
    from public.companies c
   where jsonb_typeof(c.settings -> 'depot' -> 'lat') = 'number' and jsonb_typeof(c.settings -> 'depot' -> 'lng') = 'number'
     and not (c.settings -> 'depot' ? 'source')
   order by c.id
   limit least(greatest(coalesce(p_limit, 20), 1), 100)
$$;

-- The shop's spot as it was looked up again, saved only while the spot and the company's address
-- are still what the task read: a change the office saved meanwhile stands. True when it was saved.
create function public.relocate_depot(p_company uuid, p_address jsonb, p_was jsonb, p_depot jsonb) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if jsonb_typeof(p_depot -> 'lat') is distinct from 'number' or jsonb_typeof(p_depot -> 'lng') is distinct from 'number'
     or p_depot ->> 'source' is null or p_depot ->> 'source' not in ('census', 'openstreetmap', 'unknown') then
    raise exception 'A shop''s spot has lat, lng and where it came from' using errcode = '22023';
  end if;
  update public.companies c
     set settings = jsonb_set(c.settings, '{depot}', p_depot)
   where c.id = p_company and c.settings -> 'depot' = p_was and c.address = coalesce(p_address, '{}');
  return found;
end $$;

revoke all on function private.property_located_by() from public;
revoke execute on function public.depots_to_relocate(integer), public.relocate_depot(uuid, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.depots_to_relocate(integer), public.relocate_depot(uuid, jsonb, jsonb, jsonb) to service_role;

notify pgrst, 'reload schema';
