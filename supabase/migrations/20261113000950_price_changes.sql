-- Changing prices across repeating jobs.
--
-- A company with 150 mowing clients edited 150 jobs each spring. Now the Jobs page's "Change
-- prices" changes the lines of many repeating jobs at once, by a percentage or by an amount on each
-- line's price, up or down, rounded to the cent, to 50 cents or to the dollar:
--
--   price_change_preview   what a change would do, with nothing changed: each active repeating job
--                          picked (all of them, or narrowed by a service on the job, a client tag,
--                          a crew, or the jobs ticked), each line's old and new price, the job's
--                          old and new price for a visit (or a month), totals, and for jobs on
--                          autopay whether the new price is over the company's limit.
--   apply_price_change     makes the change for the lines it's given, which must be exactly what
--                          the preview shows for their jobs at that moment (each line's old and new
--                          price, and every line of the job the change reaches): anything changed
--                          since, and nothing at all is written. One call is one transaction, so a
--                          job is never half changed; the screen sends the jobs a group at a time
--                          under one change id. Each job's activity says the old and new prices.
--   undo_price_change      puts the old prices back, for the whole change, while no invoice has
--                          been made for any of its jobs since their prices changed (a void one
--                          doesn't count). A line someone has edited or removed since is left as
--                          it is. After an invoice, changing prices again is the way back.
--   price_changes,         what was changed, by whom and when, and each line's old and new price:
--   price_change_lines     the record Undo reads, and the office's history of changes.
--
-- What it changes: lines priced above $0 on active repeating jobs (a paused job is active). Lines
-- at $0, money off (a typed discount or a promo code's line) and one-off jobs are left alone, and so
-- is extra work on one visit (visit_extras, 20261113000900_visit_extras.sql), which isn't a job
-- line. Invoices already made keep their prices: only invoices made from now on bill the new ones.
--
-- Autopay follows the rules it has: a client isn't asked to agree again because a price changed
-- (they're asked only when the terms' words do: 20261105000100_autopay_reagree.sql), so their card
-- is charged the new price from the next invoice, unless that's over the company's autopay limit,
-- when the charge waits for the office's OK as any charge over the limit does (autopay_bill). The
-- preview says which jobs those are. Nothing is sent to clients.
--
-- For owners, admins and the office with Quotes and sales, the area that edits job lines.
-- supabase/tests/price_changes_test.sql covers it.

create table public.price_changes (
  id uuid primary key,
  company_id uuid not null references public.companies (id) on delete cascade,
  -- What was asked: {kind: percent | amount, value, round: cent | half | dollar, line_service_id}.
  change jsonb not null,
  summary text not null,
  jobs integer not null default 0,
  lines integer not null default 0,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  undone_at timestamptz,
  undone_by uuid references auth.users (id) on delete set null,
  unique (company_id, id)
);
comment on table public.price_changes is 'A change of prices across repeating jobs (apply_price_change), kept so it can be undone and looked back on.';
create index price_changes_company_idx on public.price_changes (company_id, created_at desc);

create table public.price_change_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  change_id uuid not null,
  job_id uuid not null,
  -- The job line it changed. No foreign key: the record outlives a line removed later.
  line_id uuid not null,
  name text not null,
  quantity numeric(14, 3) not null,
  old_price numeric(12, 2) not null,
  new_price numeric(12, 2) not null,
  applied_at timestamptz not null default now(),
  -- When Undo put the old price back; null for a line it left alone (edited or removed since).
  restored_at timestamptz,
  foreign key (company_id, change_id) references public.price_changes (company_id, id) on delete cascade,
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade,
  unique (change_id, line_id)
);
comment on table public.price_change_lines is 'Each job line a price change changed, with its old and new price.';
create index price_change_lines_job_idx on public.price_change_lines (job_id);

-- Read by the people who can make one; written only by the functions below.
alter table public.price_changes enable row level security;
alter table public.price_change_lines enable row level security;
create policy price_changes_read on public.price_changes for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'sales'));
create policy price_change_lines_read on public.price_change_lines for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'sales'));
revoke insert, update, delete, truncate on public.price_changes, public.price_change_lines from authenticated;
revoke all on public.price_changes, public.price_change_lines from anon;

-- ---------------------------------------------------------------------------------------------
-- The change
-- ---------------------------------------------------------------------------------------------

-- Who may: owners, admins and the office, with Quotes and sales.
create function private.price_change_allowed(p_company uuid) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'sales')) then
    raise exception 'Only the office with Quotes and sales can change prices across jobs' using errcode = '42501';
  end if;
end $$;

-- A change that can be made, or an error saying what's wrong with it.
create function private.price_change_checked(p_change jsonb) returns void
language plpgsql immutable set search_path = '' as $$
declare
  v_value numeric;
begin
  if p_change ->> 'kind' is null or p_change ->> 'kind' not in ('percent', 'amount') then
    raise exception 'Choose a percentage or an amount' using errcode = '22023';
  end if;
  if jsonb_typeof(p_change -> 'value') is distinct from 'number' then
    raise exception 'Enter how much to change prices by' using errcode = '22023';
  end if;
  v_value := (p_change ->> 'value')::numeric;
  if v_value = 0 then
    raise exception 'Enter how much to change prices by' using errcode = '22023';
  end if;
  if p_change ->> 'kind' = 'percent' and (v_value <= -100 or v_value > 500) then
    raise exception 'Enter a percentage up to 500, or down by less than 100' using errcode = '22023';
  end if;
  if p_change ->> 'kind' = 'amount' and abs(v_value) > 100000 then
    raise exception 'That amount is too large' using errcode = '22023';
  end if;
  if p_change ->> 'round' is null or p_change ->> 'round' not in ('cent', 'half', 'dollar') then
    raise exception 'Choose how to round the new prices' using errcode = '22023';
  end if;
end $$;

-- A price after the change: up or down by the percentage, or by the amount, then rounded to the
-- cent, to 50 cents or to the dollar (halves away from zero), and never below $0.
create function private.price_after(p_price numeric, p_change jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select greatest(case p_change ->> 'round'
           when 'dollar' then round(x.raw)
           when 'half' then round(x.raw * 2) / 2
           else round(x.raw, 2) end, 0)::numeric(12, 2)
  from (select case p_change ->> 'kind'
                 when 'percent' then p_price * (1 + (p_change ->> 'value')::numeric / 100)
                 else p_price + (p_change ->> 'value')::numeric end as raw) x
$$;

-- "Up 5%, rounded to the dollar", "Down $2.00 a line, on Mowing lines".
create function private.price_change_summary(p_company uuid, p_change jsonb) returns text
language sql stable security definer set search_path = '' as $$
  select case when (p_change ->> 'value')::numeric > 0 then 'Up ' else 'Down ' end
    || case p_change ->> 'kind'
         when 'percent' then trim(trailing '.' from trim(trailing '0' from to_char(abs((p_change ->> 'value')::numeric), 'FM999990.0000'))) || '%'
         else private.money(abs((p_change ->> 'value')::numeric)) || ' a line' end
    || case p_change ->> 'round' when 'dollar' then ', rounded to the dollar' when 'half' then ', rounded to 50 cents' else '' end
    || coalesce(', on ' || (select s.name from public.services s where s.company_id = p_company and s.id = nullif(p_change ->> 'line_service_id', '')::uuid) || ' lines', '')
$$;

-- Whether a job line is for a price list item: it links to it, or (a line typed in, with no link)
-- has its exact name, as revenue by service reads them.
create function private.line_is_for(p_line public.job_line_items, p_service uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_line.service_id = p_service
      or (p_line.service_id is null and exists (
            select 1 from public.services s where s.id = p_service and s.company_id = p_line.company_id and lower(btrim(s.name)) = lower(btrim(p_line.name))))
$$;

-- The lines a change reaches on the company's active repeating jobs (all of them, or p_jobs), each
-- with its price now and after: priced above $0, not a promo code's line, for the change's service
-- when it names one, and only where the price really changes.
create function private.price_change_reach(p_company uuid, p_change jsonb, p_jobs uuid[] default null)
returns table (job_id uuid, line_id uuid, name text, quantity numeric, unit text, sort integer, old_price numeric, new_price numeric)
language sql stable security definer set search_path = '' as $$
  select li.job_id, li.id, li.name, li.quantity, li.unit, li.sort, li.unit_price, private.price_after(li.unit_price, p_change)
  from public.jobs j
  join public.job_line_items li on li.job_id = j.id
  where j.company_id = p_company and j.kind = 'recurring' and j.status = 'active'
    and (p_jobs is null or j.id = any (p_jobs))
    and li.unit_price > 0 and li.discount_key is null
    and (nullif(p_change ->> 'line_service_id', '') is null or private.line_is_for(li, (p_change ->> 'line_service_id')::uuid))
    and private.price_after(li.unit_price, p_change) <> li.unit_price
$$;

revoke all on function private.price_change_allowed(uuid), private.price_change_checked(jsonb), private.price_after(numeric, jsonb),
  private.price_change_summary(uuid, jsonb), private.line_is_for(public.job_line_items, uuid), private.price_change_reach(uuid, jsonb, uuid[]) from public;

/**
 * What a change would do, with nothing changed. p_change: {kind: 'percent' | 'amount', value (above
 * 0 is up, below is down), round: 'cent' | 'half' | 'dollar', line_service_id (only that item's
 * lines; all lines without it), jobs: {service_id (jobs with a line for it), client_tag, crew_id,
 * job_ids (only these)}}.
 *
 * Answers {summary, jobs: [{job_id, number, title, client_id, client, pricing ('per_visit' |
 * 'fixed'), schedule, old_price, new_price (the job's price for a visit, or a month: its lines
 * without a once-per-job discount), autopay, over_limit (on autopay, and the new price with tax is
 * over the company's limit), was_over_limit, lines: [{line_id, name, quantity, unit, old_price,
 * new_price}]}], totals: {jobs, lines, old_price, new_price}, autopay: {limit, jobs, over_limit}}.
 * Jobs the change doesn't reach aren't listed. Autopay is told only to those with the invoices area.
 */
create function public.price_change_preview(p_company uuid, p_change jsonb) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_pick jsonb := case when jsonb_typeof(p_change -> 'jobs') = 'object' then p_change -> 'jobs' else '{}'::jsonb end;
  v_only uuid[];
  v_ids uuid[];
  v_money boolean;
  v_autopay jsonb;
  v_cap numeric;
  v_tax numeric;
  v_jobs jsonb;
begin
  perform private.price_change_allowed(p_company);
  perform private.price_change_checked(p_change);
  v_money := private.has_perm(p_company, 'invoices');
  select private.autopay_of(c.settings), coalesce((c.settings ->> 'default_tax_rate')::numeric, 0) into v_autopay, v_tax
  from public.companies c where c.id = p_company;
  if not v_money or v_autopay -> 'enabled' is distinct from 'true'::jsonb then
    v_autopay := null;
  end if;
  v_cap := case when jsonb_typeof(v_autopay -> 'max_amount') = 'number' then (v_autopay -> 'max_amount')::numeric end;
  if jsonb_typeof(v_pick -> 'job_ids') = 'array' then
    select coalesce(array_agg(x::uuid), '{}') into v_only from jsonb_array_elements_text(v_pick -> 'job_ids') x;
  end if;

  select coalesce(array_agg(j.id), '{}') into v_ids
  from public.jobs j
  left join public.clients c on c.id = j.client_id
  where j.company_id = p_company and j.kind = 'recurring' and j.status = 'active'
    and (v_only is null or j.id = any (v_only))
    and (nullif(v_pick ->> 'crew_id', '') is null or j.default_crew_id = (v_pick ->> 'crew_id')::uuid)
    and (nullif(btrim(v_pick ->> 'client_tag'), '') is null
         or exists (select 1 from unnest(c.tags) t where lower(t) = lower(btrim(v_pick ->> 'client_tag'))))
    and (nullif(v_pick ->> 'service_id', '') is null
         or exists (select 1 from public.job_line_items li where li.job_id = j.id and private.line_is_for(li, (v_pick ->> 'service_id')::uuid)));

  with reach as materialized (
    select * from private.price_change_reach(p_company, p_change, v_ids)
  ),
  priced as (
    select j.id, j.number, j.title, j.client_id, c.display_name as client, j.pricing, j.invoice_schedule, j.autopay,
           coalesce(q.tax_rate, v_tax, 0) as rate,
           sum(round(li.quantity * li.unit_price, 2)) as old_price,
           sum(round(li.quantity * coalesce(r.new_price, li.unit_price), 2)) as new_price,
           coalesce(sum(round(li.quantity * li.unit_price, 2)) filter (where li.taxable), 0) as old_taxable,
           coalesce(sum(round(li.quantity * coalesce(r.new_price, li.unit_price), 2)) filter (where li.taxable), 0) as new_taxable,
           jsonb_agg(jsonb_build_object('line_id', r.line_id, 'name', r.name, 'quantity', r.quantity, 'unit', r.unit, 'old_price', r.old_price, 'new_price', r.new_price)
                     order by r.sort, r.name, r.line_id) filter (where r.line_id is not null) as lines,
           count(r.line_id) as changed
    from public.jobs j
    join public.clients c on c.id = j.client_id
    left join public.quotes q on q.id = j.quote_id
    join public.job_line_items li on li.job_id = j.id and li.discount_billing is distinct from 'once'
    left join reach r on r.line_id = li.id
    where j.id in (select job_id from reach)
    group by j.id, c.display_name, q.tax_rate
  ),
  told as (
    select p.*, p.old_price + round(p.old_taxable * p.rate, 2) as old_total, p.new_price + round(p.new_taxable * p.rate, 2) as new_total
    from priced p
  )
  select jsonb_build_object(
    'summary', private.price_change_summary(p_company, p_change),
    'jobs', coalesce(jsonb_agg(jsonb_build_object(
        'job_id', t.id, 'number', t.number, 'title', t.title, 'client_id', t.client_id, 'client', t.client,
        'pricing', case when t.pricing = 'fixed' then 'fixed' else 'per_visit' end, 'schedule', t.invoice_schedule,
        'old_price', t.old_price, 'new_price', t.new_price,
        'autopay', v_autopay is not null and t.autopay,
        'over_limit', v_cap is not null and t.autopay and t.new_total > v_cap,
        'was_over_limit', v_cap is not null and t.autopay and t.old_total > v_cap,
        'lines', t.lines) order by t.client, t.number), '[]'::jsonb),
    'totals', jsonb_build_object('jobs', count(*), 'lines', coalesce(sum(t.changed), 0),
        'old_price', coalesce(sum(t.old_price), 0), 'new_price', coalesce(sum(t.new_price), 0)),
    'autopay', case when v_autopay is null then null else jsonb_build_object('limit', v_cap,
        'jobs', count(*) filter (where t.autopay),
        'over_limit', count(*) filter (where v_cap is not null and t.autopay and t.new_total > v_cap and t.old_total <= v_cap)) end)
  into v_jobs
  from told t;
  return v_jobs;
end $$;

/**
 * Make a change for the lines given: p_lines is [{line_id, old_price, new_price}], as the preview
 * listed them, for one group of jobs. Nothing is written unless they're exactly what the change does
 * to those jobs now: every line it reaches on each job, at the price it has and the price it gets.
 * p_id is the change's id, made by whoever starts it, the same for each group of one change; a
 * group sent twice is applied once. Returns {jobs, lines} for this group (and again: true when it
 * was already applied).
 */
create function public.apply_price_change(p_company uuid, p_id uuid, p_change jsonb, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_what jsonb := p_change - 'jobs';
  v_jobs uuid[];
  v_given integer;
  v_done integer;
  v_change public.price_changes;
  v_new uuid[];
  v_bad bigint;
  v_summary text;
  r record;
begin
  perform private.price_change_allowed(p_company);
  perform private.price_change_checked(p_change);
  if p_id is null or jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Preview the change first' using errcode = '22023';
  end if;
  -- One change at a time for a company, so two people's changes don't cross.
  perform pg_advisory_xact_lock(hashtextextended('price-change:' || p_company::text, 0));

  select * into v_change from public.price_changes where id = p_id;
  if found and (v_change.company_id <> p_company or v_change.undone_at is not null or v_change.change <> v_what) then
    raise exception 'That change was already made or undone. Preview it again' using errcode = '22023';
  end if;

  select count(*), count(*) filter (where exists (select 1 from public.price_change_lines l where l.change_id = p_id and l.line_id = g.line_id))
    into v_given, v_done
  from jsonb_to_recordset(p_lines) g (line_id uuid, old_price numeric, new_price numeric);
  if v_done > 0 and v_done = v_given then
    -- This group, sent again after its answer was lost.
    return jsonb_build_object('jobs', (select count(distinct l.job_id) from public.price_change_lines l where l.change_id = p_id
                                        and l.line_id in (select g.line_id from jsonb_to_recordset(p_lines) g (line_id uuid))),
                              'lines', v_done, 'again', true);
  end if;

  select array_agg(distinct li.job_id) into v_jobs
  from jsonb_to_recordset(p_lines) g (line_id uuid, old_price numeric, new_price numeric)
  join public.job_line_items li on li.id = g.line_id
  join public.jobs j on j.id = li.job_id and j.company_id = p_company;
  if v_jobs is null then
    raise exception 'Something changed since the preview. Preview again, then apply' using errcode = '22023';
  end if;
  -- Held while they're compared and changed.
  perform 1 from public.job_line_items li where li.job_id = any (v_jobs) for update;

  select max(coalesce(j.number, 0)) into v_bad
  from private.price_change_reach(p_company, p_change, v_jobs) e
  full join jsonb_to_recordset(p_lines) g (line_id uuid, old_price numeric, new_price numeric) on g.line_id = e.line_id
  left join public.jobs j on j.id = e.job_id
  where e.line_id is null or g.line_id is null or g.old_price is distinct from e.old_price or g.new_price is distinct from e.new_price;
  if v_bad is not null then
    raise exception 'Something changed since the preview%. Preview again, then apply',
      case when v_bad > 0 then ' (job #' || v_bad || ')' else '' end using errcode = '22023';
  end if;

  v_summary := private.price_change_summary(p_company, p_change);
  insert into public.price_changes (id, company_id, change, summary, created_by)
  values (p_id, p_company, v_what, v_summary, (select auth.uid()))
  on conflict (id) do nothing;

  with added as (
    insert into public.price_change_lines (company_id, change_id, job_id, line_id, name, quantity, old_price, new_price)
    select p_company, p_id, e.job_id, e.line_id, e.name, e.quantity, e.old_price, e.new_price
    from private.price_change_reach(p_company, p_change, v_jobs) e
    returning id
  )
  select array_agg(id) into v_new from added;
  update public.job_line_items li set unit_price = l.new_price
  from public.price_change_lines l where l.id = any (v_new) and li.id = l.line_id;
  update public.price_changes set jobs = jobs + cardinality(v_jobs), lines = lines + cardinality(v_new) where id = p_id;

  -- Each job's activity: what its price was and is, and each line's.
  for r in
    select j.id, j.number, j.client_id, case when j.pricing = 'fixed' then 'a month' else 'a visit' end as per,
           (select coalesce(sum(round(li.quantity * li.unit_price, 2)), 0) from public.job_line_items li
             where li.job_id = j.id and li.discount_billing is distinct from 'once') as now_price,
           sum(round(l.quantity * l.new_price, 2) - round(l.quantity * l.old_price, 2)) as delta,
           string_agg(l.name || ' ' || private.money(l.old_price) || ' to ' || private.money(l.new_price), ', ' order by l.name) as lines_text,
           jsonb_agg(jsonb_build_object('line_id', l.line_id, 'name', l.name, 'old_price', l.old_price, 'new_price', l.new_price) order by l.name) as lines
    from public.price_change_lines l join public.jobs j on j.id = l.job_id
    where l.id = any (v_new)
    group by j.id
  loop
    perform private.emit(p_company, 'job.prices_changed', 'job', r.id,
      format('Prices changed on job #%s for %s: %s to %s %s (%s)', r.number, private.client_name(r.client_id),
             private.money(r.now_price - r.delta), private.money(r.now_price), r.per, r.lines_text),
      jsonb_build_object('number', r.number, 'change_id', p_id, 'change', v_summary, 'old_price', r.now_price - r.delta, 'new_price', r.now_price, 'lines', r.lines));
  end loop;
  return jsonb_build_object('jobs', cardinality(v_jobs), 'lines', cardinality(v_new));
end $$;

-- The first invoice (not void) made for one of a change's jobs since its prices changed: what
-- stops Undo. Null when there's none.
create function private.price_change_invoiced(p_change uuid) returns bigint
language sql stable security definer set search_path = '' as $$
  select i.number
  from public.invoices i
  join (select l.job_id, min(l.applied_at) as applied_at from public.price_change_lines l where l.change_id = p_change group by l.job_id) c on c.job_id = i.job_id
  where i.status <> 'void' and i.created_at >= c.applied_at
  order by i.created_at, i.number limit 1
$$;
revoke all on function private.price_change_invoiced(uuid) from public;

/**
 * Undo a whole change: every line it changed goes back to its old price, unless someone has edited
 * or removed the line since (those are left as they are). Refused once an invoice has been made for
 * any of its jobs since their prices changed. Returns {restored, left}.
 */
create function public.undo_price_change(p_company uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_change public.price_changes;
  v_invoice bigint;
  v_restored integer;
  v_lines integer;
  r record;
begin
  perform private.price_change_allowed(p_company);
  perform pg_advisory_xact_lock(hashtextextended('price-change:' || p_company::text, 0));
  select * into v_change from public.price_changes where id = p_id and company_id = p_company for update;
  if not found then
    raise exception 'That price change wasn''t found' using errcode = 'P0002';
  end if;
  if v_change.undone_at is not null then
    raise exception 'That price change was already undone' using errcode = '22023';
  end if;
  v_invoice := private.price_change_invoiced(p_id);
  if v_invoice is not null then
    raise exception 'Invoice #% was made at the new prices, so this change can''t be undone. Change prices again to move them back', v_invoice using errcode = '22023';
  end if;

  with back as (
    update public.job_line_items li set unit_price = l.old_price
    from public.price_change_lines l
    where l.change_id = p_id and li.id = l.line_id and li.unit_price = l.new_price
    returning l.id
  ),
  marked as (
    update public.price_change_lines l set restored_at = now() where l.id in (select id from back) returning 1
  )
  select count(*) into v_restored from marked;
  select count(*) into v_lines from public.price_change_lines where change_id = p_id;
  update public.price_changes set undone_at = now(), undone_by = (select auth.uid()) where id = p_id;

  for r in
    select j.id, j.number, j.client_id, case when j.pricing = 'fixed' then 'a month' else 'a visit' end as per,
           (select coalesce(sum(round(li.quantity * li.unit_price, 2)), 0) from public.job_line_items li
             where li.job_id = j.id and li.discount_billing is distinct from 'once') as now_price
    from public.jobs j
    where j.id in (select l.job_id from public.price_change_lines l where l.change_id = p_id and l.restored_at is not null)
  loop
    perform private.emit(p_company, 'job.prices_changed', 'job', r.id,
      format('Price change undone on job #%s for %s: back to %s %s', r.number, private.client_name(r.client_id), private.money(r.now_price), r.per),
      jsonb_build_object('number', r.number, 'change_id', p_id, 'undone', true, 'new_price', r.now_price));
  end loop;
  return jsonb_build_object('restored', v_restored, 'left', v_lines - v_restored);
end $$;

/**
 * The company's latest price changes, newest first: [{id, summary, jobs, lines, created_at, by,
 * undone_at, invoice (the invoice that stops Undo, or null)}].
 */
create function public.price_change_history(p_company uuid, p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.price_change_allowed(p_company);
  return (
    select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'summary', c.summary, 'jobs', c.jobs, 'lines', c.lines, 'created_at', c.created_at,
             'by', (select p.full_name from public.profiles p where p.user_id = c.created_by), 'undone_at', c.undone_at,
             'invoice', case when c.undone_at is null then private.price_change_invoiced(c.id) end) order by c.created_at desc), '[]'::jsonb)
    from (select * from public.price_changes x where x.company_id = p_company order by x.created_at desc limit least(greatest(coalesce(p_limit, 10), 1), 50)) c
  );
end $$;

revoke execute on function public.price_change_preview(uuid, jsonb), public.apply_price_change(uuid, uuid, jsonb, jsonb),
  public.undo_price_change(uuid, uuid), public.price_change_history(uuid, integer) from public, anon;
grant execute on function public.price_change_preview(uuid, jsonb), public.apply_price_change(uuid, uuid, jsonb, jsonb),
  public.undo_price_change(uuid, uuid), public.price_change_history(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- AI assistants
-- ---------------------------------------------------------------------------------------------

-- As in 20261113000440_edit_sent_invoices.sql, plus making and undoing a price change, which change
-- job lines: for an assistant that may change jobs.
create or replace function private.assistant_rpc_area(p_function text) returns text
language sql immutable set search_path = '' as $$
  select case p_function
    when 'apply_price_change' then 'jobs'
    when 'convert_quote_to_job' then 'quotes'
    when 'create_invoice_for_job' then 'invoices'
    when 'duplicate_quote' then 'quotes'
    when 'edit_invoice' then 'invoices'
    when 'merge_clients' then 'invoices'
    when 'merge_company_settings' then 'company'
    when 'quote_exact_sent' then 'quotes'
    when 'remove_late_fee' then 'invoices'
    when 'set_checklist_services' then 'checklists'
    when 'set_weather_rules' then 'prices'
    when 'undo_price_change' then 'jobs'
  end
$$;

select private.fold_member_checks('public.price_changes');
select private.fold_member_checks('public.price_change_lines');

notify pgrst, 'reload schema';
