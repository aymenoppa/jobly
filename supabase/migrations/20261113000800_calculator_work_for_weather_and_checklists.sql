-- A job priced with the paving calculator has one line named after the job type, with no price list
-- item behind it. Weather rules matched price list items by id or name, and checklists came up by
-- price list item, so an asphalt job priced the usual paving way got no temperature hold and no
-- checklist. Now:
--
--   quote_line_items.parts,          what a line with no price list item is made of: the calculator's
--   job_line_items.parts             items the bid has any of, each with its amount, what one costs
--                                    and the kind of work it is (packages/core/src/paving.ts LinePart,
--                                    PAVING_WORK). The job's line takes its quote line's as it's made.
--   settings.weather_rules[].work    a rule can be for a kind of calculator work instead of a price
--                                    list item (set_weather_rules keeps it; the weather task matches it
--                                    against the job's parts, packages/core/src/weather.ts).
--   checklist_templates.every_job    a checklist can come up by itself on every job,
--   checklist_templates.work         or on jobs priced with the calculator that have a kind of work
--                                    (job_checklists).
--
-- Rules and checklists saved before this keep working as they were. A paving business whose rules
-- still have the starter "Hot-mix asphalt surface" or "Sealcoat" rule gets the same limits for that
-- kind of calculator work, and a checklist that goes with "Hot-mix asphalt surface" comes up on
-- calculator jobs with asphalt too (private.add_calculator_work, below).
-- supabase/tests/calculator_work_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- What a calculator line is made of
-- ---------------------------------------------------------------------------------------------

alter table public.quote_line_items add column parts jsonb check (parts is null or (jsonb_typeof(parts) = 'array' and pg_column_size(parts) <= 20000));
alter table public.job_line_items add column parts jsonb check (parts is null or (jsonb_typeof(parts) = 'array' and pg_column_size(parts) <= 20000));
comment on column public.quote_line_items.parts is 'What a line with no price list item is made of (the paving calculator''s items: amount, cost and kind of work each). Null for every other line.';
comment on column public.job_line_items.parts is 'Its quote line''s parts, taken as the line went on the job. Weather rules, checklists and job costs go by them.';

/** The kinds of paving calculator work, as packages/core/src/paving.ts PAVING_WORK names them; null for anything else. */
create function private.paving_work_label(p_work text) returns text
language sql immutable set search_path = '' as $$
  select case p_work
    when 'asphalt' then 'Hot-mix asphalt'
    when 'tar_chip' then 'Tar and chip'
    when 'sealcoat' then 'Sealcoat'
    when 'striping' then 'Striping'
    when 'stone' then 'Stone base and gravel'
    when 'milling' then 'Milling'
  end
$$;

-- Every way a quote's line goes on a job (convert_quote_to_job, apply_change_order) copies the
-- fields every line has. A line with no price list item takes what its quote line is made of here,
-- found by what was copied: the same quote, name, amount, price and cost.
create function private.job_line_parts() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.service_id is null and new.parts is null then
    select l.parts into new.parts
    from public.jobs j
    join public.quote_line_items l on l.company_id = j.company_id and l.quote_id = coalesce(new.source_quote_id, j.quote_id)
    where j.id = new.job_id and j.company_id = new.company_id
      and l.parts is not null and l.selected and l.service_id is null
      and l.name = new.name and l.quantity = new.quantity and l.unit_price = new.unit_price and l.unit_cost is not distinct from new.unit_cost
    order by (l.sort = new.sort) desc, l.sort
    limit 1;
  end if;
  return new;
end $$;
create trigger quote_line_parts before insert on public.job_line_items for each row execute function private.job_line_parts();

-- ---------------------------------------------------------------------------------------------
-- Checklists for every job, and for kinds of calculator work
-- ---------------------------------------------------------------------------------------------

alter table public.checklist_templates
  add column every_job boolean not null default false,
  add column work text[] not null default '{}'
    check (work <@ array['asphalt', 'tar_chip', 'sealcoat', 'striping', 'stone', 'milling']);
comment on column public.checklist_templates.every_job is 'It comes up by itself on every job''s visits, whatever the job has.';
comment on column public.checklist_templates.work is 'The kinds of paving calculator work it goes with: it comes up on jobs priced with the calculator that have any of them.';

/**
 * As in 20261103000300_checklists_by_service.sql, with the two new ways a checklist comes up: on
 * every job, and on a job whose calculator lines have one of its kinds of work. For whoever sees the
 * job's work, as before: the crew can't read the lines.
 */
create or replace function public.job_checklists(p_job uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select t.id
  from public.jobs j
  join public.checklist_templates t on t.company_id = j.company_id and t.active
  where j.id = p_job
    and (private.has_role(j.company_id, '{owner,admin,office,estimator,crew_lead}')
         or (private.is_member(j.company_id) and private.crew_sees_job(j.id))
         or (j.company_id = any (private.sub_companies()) and private.crew_sees_job(j.id)))
    and (t.every_job
         or exists (select 1 from public.job_line_items li
                    join public.checklist_template_services cs on cs.company_id = j.company_id and cs.service_id = li.service_id
                    where li.job_id = j.id and cs.template_id = t.id)
         or (t.work <> '{}' and exists (
               select 1 from public.job_line_items li
               cross join lateral jsonb_array_elements(case when jsonb_typeof(li.parts) = 'array' then li.parts else '[]' end) p
               where li.job_id = j.id and p.value ->> 'work' = any (t.work))))
$$;

-- ---------------------------------------------------------------------------------------------
-- Weather rules for kinds of calculator work
-- ---------------------------------------------------------------------------------------------

/**
 * As in 20261106000400_weather_rule_ids.sql, with `work`: a rule for a kind of paving calculator
 * work keeps the kind, and is called by it ("Hot-mix asphalt (paving calculator)") rather than by a
 * price list item. The name goes with it so that an app or server from before kinds reads it as a
 * rule for an item of that name, which matches nothing, and never as a rule for every job.
 */
create or replace function public.set_weather_rules(p_company uuid, p_rules jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_rule jsonb;
  v_name text;
  v_service uuid;
  v_found text;
  v_work text;
  v_clean jsonb;
  v_limit record;
  v_saved jsonb := '[]';
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'settings')) then
    raise exception 'Your role can''t change weather rules.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_rules) is distinct from 'array' then
    raise exception 'Weather rules are a list of up to 50.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rules) > 50 then
    raise exception 'Weather rules are a list of up to 50.' using errcode = '22023';
  end if;
  for v_rule in select value from jsonb_array_elements(p_rules) loop
    if jsonb_typeof(v_rule) <> 'object' then
      raise exception 'Each weather rule is a set of limits.' using errcode = '22023';
    end if;
    v_name := nullif(trim(v_rule ->> 'applies_to'), '');
    v_service := null;
    v_found := null;
    v_work := null;
    if coalesce(jsonb_typeof(v_rule -> 'work'), 'null') <> 'null' then
      if jsonb_typeof(v_rule -> 'work') <> 'string' or private.paving_work_label(v_rule ->> 'work') is null then
        raise exception 'A weather rule''s kind of paving work is one of: asphalt, tar_chip, sealcoat, striping, stone, milling.' using errcode = '22023';
      end if;
      v_work := v_rule ->> 'work';
      v_name := private.paving_work_label(v_work) || ' (paving calculator)';
    elsif coalesce(jsonb_typeof(v_rule -> 'service_id'), 'null') <> 'null' then
      if jsonb_typeof(v_rule -> 'service_id') = 'string' and pg_catalog.pg_input_is_valid(v_rule ->> 'service_id', 'uuid') then
        select s.id, s.name into v_service, v_found from public.services s where s.company_id = p_company and s.id = (v_rule ->> 'service_id')::uuid;
      end if;
      -- An item that's gone (or was never this business's) falls back to the rule's name; without
      -- one, the rule would be for every job.
      if v_service is null and v_name is null then
        raise exception 'A weather rule is for an item that isn''t on your price list.' using errcode = '22023';
      end if;
    end if;
    if v_work is null and v_service is null and v_name is not null then
      -- By name: the item of that name, an active one first.
      select s.id, s.name into v_service, v_found from public.services s
      where s.company_id = p_company and lower(trim(s.name)) = lower(v_name)
      order by s.active desc, s.created_at, s.id limit 1;
    end if;
    -- The item's name as it's called now goes with its id.
    v_name := coalesce(v_found, v_name);
    if length(v_name) > 200 then
      raise exception 'The work a weather rule is for is 200 characters at most.' using errcode = '22023';
    end if;
    v_clean := case when v_name is null then '{}' else jsonb_build_object('applies_to', v_name) end
            || case when v_service is null then '{}' else jsonb_build_object('service_id', v_service) end
            || case when v_work is null then '{}' else jsonb_build_object('work', v_work) end;
    for v_limit in
      select * from (values
        ('max_rain_pct', 0, 100, 'The most rain chance is 0 to 100%.'),
        ('min_temp_f', -40, 130, 'The lowest temperature is -40°F to 130°F.'),
        ('max_temp_f', -40, 130, 'The highest temperature is -40°F to 130°F.'),
        ('max_wind_mph', 0, 100, 'The most wind is 0 to 100 mph.'),
        ('requires_dry_hours', 1, 168, 'Dry hours after are 1 to 168.')) l(field, low, high, message)
    loop
      continue when coalesce(jsonb_typeof(v_rule -> v_limit.field), 'null') = 'null';
      if jsonb_typeof(v_rule -> v_limit.field) <> 'number' then
        raise exception '%', v_limit.message using errcode = '22023';
      end if;
      if (v_rule ->> v_limit.field)::numeric not between v_limit.low and v_limit.high then
        raise exception '%', v_limit.message using errcode = '22023';
      end if;
      v_clean := v_clean || jsonb_build_object(v_limit.field, v_rule -> v_limit.field);
    end loop;
    if v_clean - 'applies_to' - 'service_id' - 'work' = '{}' then
      raise exception 'A weather rule needs at least one limit: rain, temperature, wind or dry hours.' using errcode = '22023';
    end if;
    if (v_clean ->> 'min_temp_f')::numeric > (v_clean ->> 'max_temp_f')::numeric then
      raise exception 'A weather rule''s lowest temperature has to be below its highest.' using errcode = '22023';
    end if;
    v_saved := v_saved || jsonb_build_array(v_clean);
  end loop;
  update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{weather_rules}', v_saved) where id = p_company;
  return v_saved;
end $$;
revoke execute on function public.set_weather_rules(uuid, jsonb) from public, anon;
grant execute on function public.set_weather_rules(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Paving businesses already here
-- ---------------------------------------------------------------------------------------------

-- Only where it's plain what was meant: a business with Paving installed whose rules still have one
-- for an item called exactly "Hot-mix asphalt surface" or "Sealcoat" (the starter rules), and none
-- yet for that kind of calculator work, gets the same limits for the calculator's asphalt or
-- sealcoat, added after its own rules, which stay as they are. A checklist that goes with an item
-- called "Hot-mix asphalt surface" comes up on calculator jobs with asphalt too. Kept, so the
-- database tests can run it on rules saved the old way. Returns how many businesses got a rule.
create function private.add_calculator_work() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  with wanted as (
    select c.id, jsonb_agg((e.r - 'applies_to' - 'service_id') || jsonb_build_object('work', k.work, 'applies_to', private.paving_work_label(k.work) || ' (paving calculator)') order by e.n) as added
    from public.companies c
    cross join lateral jsonb_array_elements(c.settings -> 'weather_rules') with ordinality as e(r, n)
    join (values ('hot-mix asphalt surface', 'asphalt'), ('sealcoat', 'sealcoat')) k(name, work)
      on jsonb_typeof(e.r) = 'object' and not e.r ? 'work' and lower(trim(e.r ->> 'applies_to')) = k.name
    where c.settings -> 'paving_app' ->> 'enabled' = 'true'
      and jsonb_typeof(c.settings -> 'weather_rules') = 'array'
      and jsonb_array_length(c.settings -> 'weather_rules') <= 40
      and not exists (select 1 from jsonb_array_elements(c.settings -> 'weather_rules') o where jsonb_typeof(o.value) = 'object' and o.value ->> 'work' = k.work)
      -- One rule for the item, so there's one set of limits to copy.
      and (select count(*) from jsonb_array_elements(c.settings -> 'weather_rules') o
           where jsonb_typeof(o.value) = 'object' and not o.value ? 'work' and lower(trim(o.value ->> 'applies_to')) = k.name) = 1
    group by c.id
  )
  update public.companies c
  set settings = jsonb_set(c.settings, '{weather_rules}', (c.settings -> 'weather_rules') || w.added)
  from wanted w where w.id = c.id;
  get diagnostics v_count = row_count;

  update public.checklist_templates t
  set work = '{asphalt}'
  from public.companies c
  where c.id = t.company_id and c.settings -> 'paving_app' ->> 'enabled' = 'true'
    and t.work = '{}' and not t.every_job
    and exists (select 1 from public.checklist_template_services cs
                join public.services s on s.company_id = cs.company_id and s.id = cs.service_id
                where cs.template_id = t.id and lower(trim(s.name)) = 'hot-mix asphalt surface');
  return v_count;
end $$;
revoke all on function private.add_calculator_work() from public;
select private.add_calculator_work();

notify pgrst, 'reload schema';
