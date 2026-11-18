-- Job costs count labor and materials once on a job priced with the paving calculator, and on a job
-- whose supplier invoice is entered as an expense.
--
--   quote_line_items.unit_labor_cost   the labor in a line's unit cost, for a line with no price list
--                                      item to say (the paving calculator's: its crew days). The job's
--                                      line takes it with the line's parts (private.job_line_parts),
--                                      and job costs leave it out once the job has labor of its own,
--                                      as they do for a price list item's labor (20261025003004).
--                                      Lines the calculator already priced get it from their
--                                      worksheets, on quotes and on the jobs made from them.
--   expenses.in_line_costs             the office's tick on an expense: "already in the job's line
--                                      item costs" (the supplier's invoice for materials the estimate
--                                      covers). Job costs don't add it on top of the lines.
--   job_estimated_materials(job)       what's on a job by name and unit, with no prices, for the Log
--                                      material list: its price list items and its calculator lines'
--                                      materials. A material logged as one of them is compared with
--                                      the estimate, and counts in its place (packages/core/src/
--                                      reports.ts materialUse).
-- supabase/tests/job_costs_once_test.sql covers it.

alter table public.quote_line_items add column unit_labor_cost numeric(12, 2) check (unit_labor_cost >= 0);
comment on column public.quote_line_items.unit_labor_cost is 'The labor in unit_cost, for a line with no price list item (the paving calculator''s crew days). The job''s line takes it.';

-- As in 20261113000800, with the labor in the line's cost taken along with what it's made of.
create or replace function private.job_line_parts() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_parts jsonb;
  v_labor numeric;
  v_found boolean := false;
begin
  if new.service_id is null and (new.parts is null or new.unit_labor_cost is null) then
    select true, l.parts, l.unit_labor_cost into v_found, v_parts, v_labor
    from public.jobs j
    join public.quote_line_items l on l.company_id = j.company_id and l.quote_id = coalesce(new.source_quote_id, j.quote_id)
    where j.id = new.job_id and j.company_id = new.company_id
      and (l.parts is not null or l.unit_labor_cost is not null) and l.selected and l.service_id is null
      and l.name = new.name and l.quantity = new.quantity and l.unit_price = new.unit_price and l.unit_cost is not distinct from new.unit_cost
    order by (l.sort = new.sort) desc, l.sort
    limit 1;
    if v_found then
      new.parts := coalesce(new.parts, v_parts);
      new.unit_labor_cost := coalesce(new.unit_labor_cost, v_labor);
    end if;
  end if;
  return new;
end $$;

alter table public.expenses add column in_line_costs boolean not null default false;
comment on column public.expenses.in_line_costs is 'The office marked it as already in its job''s line item costs (the supplier''s invoice for materials the estimate covers): job costs don''t count it again.';

/**
 * What's on a job that a material can be logged against, by name and unit and nothing else: each
 * price list item on its lines, and each material a paving calculator line is made of. For whoever
 * logs materials on the job (the office, and the crew on its visits), who can't all read the lines.
 */
create function public.job_estimated_materials(p_job uuid)
returns table (service_id uuid, name text, unit text)
language sql stable security definer set search_path = '' as $$
  with job as (
    select j.id from public.jobs j
    where j.id = p_job
      and (private.has_role(j.company_id, '{owner,admin,office,estimator,crew_lead}')
           or (private.is_member(j.company_id) and private.crew_sees_job(j.id)))
  )
  select distinct on (li.service_id) li.service_id, s.name, li.unit
  from job
  join public.job_line_items li on li.job_id = job.id
  join public.services s on s.company_id = li.company_id and s.id = li.service_id
  where li.unit_price >= 0
  union all
  select distinct null::uuid, p.value ->> 'name', p.value ->> 'unit'
  from job
  join public.job_line_items li on li.job_id = job.id
  cross join lateral jsonb_array_elements(case when jsonb_typeof(li.parts) = 'array' then li.parts else '[]' end) p
  where p.value ->> 'material' = 'true' and nullif(trim(p.value ->> 'name'), '') is not null and p.value ->> 'unit' is not null
$$;
revoke execute on function public.job_estimated_materials(uuid) from public, anon;
grant execute on function public.job_estimated_materials(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Lines the calculator already priced
-- ---------------------------------------------------------------------------------------------

-- A worksheet keeps the bid it priced its line at: the labor in that line's cost is its crew days
-- (items figured by the day and marked as a crew day), each at its day price. Only for a line that
-- still costs what a bid with that labor could (the labor isn't more than the cost), and never for
-- a crew item with choices, whose price depends on the one picked. The jobs made from those quotes
-- get it on the line that was copied from the quote's. Without touching the quotes or jobs: their
-- updated_at is when they were last changed, which Finance → Profit goes by. Kept, so the database
-- tests can run it on lines priced before this. Returns how many quote lines it filled in.
create function private.fill_calculator_labor() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_count integer;
begin
  alter table public.quote_line_items disable trigger touch_quote;
  alter table public.job_line_items disable trigger touch_job;

  with labor as (
    select w.line_id, round(sum((w.data -> 'input' -> 'values' ->> (i.value ->> 'id'))::numeric * (i.value ->> 'price')::numeric), 2) as amount,
           coalesce(bool_or(jsonb_typeof(i.value -> 'choices') = 'array' and jsonb_array_length(i.value -> 'choices') > 0), false) as has_choices
    from public.paving_worksheets w
    cross join lateral jsonb_array_elements(case when jsonb_typeof(w.data -> 'setup' -> 'items') = 'array' then w.data -> 'setup' -> 'items' else '[]' end) i
    where w.line_id is not null
      and i.value ->> 'basis' = 'days' and i.value -> 'crew' = 'true'
      and jsonb_typeof(i.value -> 'price') = 'number' and jsonb_typeof(w.data -> 'input' -> 'values' -> (i.value ->> 'id')) = 'number'
    group by w.line_id
  )
  update public.quote_line_items l
  set unit_labor_cost = labor.amount
  from labor
  where l.id = labor.line_id and l.unit_labor_cost is null and l.service_id is null and l.quantity = 1
    and not labor.has_choices and labor.amount > 0 and labor.amount <= l.unit_cost;
  get diagnostics v_count = row_count;

  update public.job_line_items jl
  set unit_labor_cost = l.unit_labor_cost
  from public.jobs j, public.quote_line_items l
  where j.id = jl.job_id and l.company_id = j.company_id and l.quote_id = coalesce(jl.source_quote_id, j.quote_id)
    and jl.unit_labor_cost is null and jl.service_id is null
    and l.unit_labor_cost is not null and l.selected and l.service_id is null
    and l.name = jl.name and l.quantity = jl.quantity and l.unit_price = jl.unit_price and l.unit_cost = jl.unit_cost
    and exists (select 1 from public.paving_worksheets w where w.line_id = l.id);

  alter table public.quote_line_items enable trigger touch_quote;
  alter table public.job_line_items enable trigger touch_job;
  return v_count;
end $$;
revoke all on function private.fill_calculator_labor() from public;
select private.fill_calculator_labor();

notify pgrst, 'reload schema';
