-- Snow: the business's standard storm prices, so every snow customer is priced the same way.
--
-- settings.snow_storm_prices is a list of depth bands, [{ "up_to_in": 3, "times": 1 }, ...]: a storm
-- that deep bills that multiple of what one push bills the customer (the job's own lines). The last
-- band has no depth and covers anything deeper. The Snow page fills a customer's own storm prices
-- (snow_sites.tiers) from it; billing still reads only the customer's.
--
-- Whoever may price a snow customer (snow_sites: owner, admin, office) may set the standard.

create function public.set_snow_storm_prices(p_company uuid, p_bands jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.has_role(p_company, '{owner,admin,office}') then
    raise exception 'Your role can''t change the standard storm prices.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_bands) is distinct from 'array' or jsonb_array_length(p_bands) > 8 then
    raise exception 'The standard storm prices are up to 8 depths.' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_bands) b
     where case
             when jsonb_typeof(b) <> 'object' or jsonb_typeof(b -> 'times') is distinct from 'number' then true
             when (b ->> 'times')::numeric <= 0 or (b ->> 'times')::numeric > 100 then true
             when b -> 'up_to_in' is null or jsonb_typeof(b -> 'up_to_in') = 'null' then false
             when jsonb_typeof(b -> 'up_to_in') <> 'number' then true
             else (b ->> 'up_to_in')::numeric <= 0 or (b ->> 'up_to_in')::numeric > 100
           end) then
    raise exception 'Each depth needs a multiple above 0, and inches above 0 if it has them.' using errcode = '22023';
  end if;
  if (select count(*) from jsonb_array_elements(p_bands) b where b -> 'up_to_in' is null or jsonb_typeof(b -> 'up_to_in') = 'null') > 1 then
    raise exception 'Only the last depth can be left open.' using errcode = '22023';
  end if;
  update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{snow_storm_prices}', p_bands) where id = p_company;
  return p_bands;
end $$;
revoke execute on function public.set_snow_storm_prices(uuid, jsonb) from public, anon;
grant execute on function public.set_snow_storm_prices(uuid, jsonb) to authenticated;
