-- Jobly - Snow, a built-in app like Paving and Roofing (Apps → Jobly - Snow, settings.snow_app).
-- A snow customer is one of the business's jobs with what the Snow page keeps about it: the inches
-- of snow that send the plow out, and how it's served. The snow task (snowWatch in
-- apps/api/src/tasks.ts) tells the job's crew, the people listed on it and the people who schedule
-- the team, the day before and once for that day, when the snow forecast from 6pm that day through
-- the next reaches the trigger; it warns salting customers of ice and refreeze; and it writes each
-- storm into a log. Nothing is scheduled by itself: the office does that from the Snow page
-- (snow_schedule), which puts those same people on the visits.
--
--   snow_sites          the snow customers: a job's triggers and service level
--   snow_site_people    who else works one besides its crew (a sub, a driver on no crew)
--   snow_events         the storm log: a job's snow day, what was forecast and what fell
--   snow_visits         the visits made for a storm, so it can be priced, reported and told about
--   snow_availability   who was asked whether they can go out, and what they said
--   visits.price        what one visit bills, in place of the job's lines (a storm billed by depth)
--
-- The forecast source every weather feature uses is settings.weather_source (set_weather_source).
-- supabase/tests/snow_app_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- Snow customers
-- ---------------------------------------------------------------------------------------------

-- A storm's price by how much fell: [{"up_to_in": 4, "price": 75}, {"up_to_in": null, "price": 140}],
-- the last one open-ended. Up to eight, each a price of zero or more.
create function private.snow_tiers_ok(p_tiers jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p_tiers) = 'array' and jsonb_array_length(p_tiers) <= 8 and not exists (
    select 1 from jsonb_array_elements(p_tiers) t
    where jsonb_typeof(t) <> 'object'
       or jsonb_typeof(t -> 'price') is distinct from 'number' or (t ->> 'price')::numeric < 0 or (t ->> 'price')::numeric > 1000000
       or coalesce(jsonb_typeof(t -> 'up_to_in'), 'null') not in ('number', 'null')
       or (jsonb_typeof(t -> 'up_to_in') = 'number' and ((t ->> 'up_to_in')::numeric <= 0 or (t ->> 'up_to_in')::numeric > 100)))
$$;

create table public.snow_sites (
  company_id uuid not null,
  job_id uuid primary key,
  trigger_in numeric(4, 1) not null check (trigger_in > 0 and trigger_in <= 48),      -- plow at this much snow
  salt_trigger_in numeric(4, 1) check (salt_trigger_in > 0 and salt_trigger_in <= 48), -- salt at this much, and for ice; null: no salting
  repeat_in numeric(4, 1) check (repeat_in > 0 and repeat_in <= 48),                   -- another push for every this much past the trigger; null: one push
  clear_by time,                                                                       -- cleared by this time of day; null: no promise
  priority smallint not null default 2 check (priority between 1 and 3),               -- 1 first
  tiers jsonb not null default '[]' check (private.snow_tiers_ok(tiers)),              -- a storm's price by depth; empty: each push bills the job's lines
  tell_client boolean not null default false,                                          -- the client hears when it's scheduled and when it's done
  alerted_on date,           -- the snow day its people were last told about, so they're told once
  alerted_pushes smallint,   -- how many pushes they were told then (0: salt only), so more snow is news
  ice_alerted_on date,       -- the day they were last warned about ice or refreeze for
  created_at timestamptz not null default now(),
  check (salt_trigger_in is null or salt_trigger_in < trigger_in),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade
);
create index snow_sites_company_idx on public.snow_sites (company_id);
select private.apply_policies('snow_sites', '{owner,admin,office}', '{owner,admin,office}');

create table public.snow_site_people (
  company_id uuid not null,
  job_id uuid not null references public.snow_sites (job_id) on delete cascade,
  user_id uuid not null,
  primary key (job_id, user_id),
  -- Someone in this company: the team or a sub's sign-in.
  foreign key (company_id, user_id) references public.memberships (company_id, user_id) on delete cascade
);
create index snow_site_people_user_idx on public.snow_site_people (company_id, user_id);
select private.apply_policies('snow_site_people', '{owner,admin,office}', '{owner,admin,office}');

-- ---------------------------------------------------------------------------------------------
-- The storm log, and what a storm's visits bill
-- ---------------------------------------------------------------------------------------------

create table public.snow_events (
  company_id uuid not null,
  job_id uuid not null,
  snow_date date not null,
  kind text not null default 'plow' check (kind in ('plow', 'salt')),
  forecast_in numeric(5, 2) check (forecast_in >= 0),  -- what was forecast when its people were told or it was scheduled
  actual_in numeric(5, 2) check (actual_in >= 0),      -- what fell: the forecast source's own estimate afterwards, or what the office wrote
  actual_by uuid references auth.users (id) on delete set null, -- who wrote it; null: the estimate
  pushes smallint not null default 1 check (pushes between 1 and 12),
  created_at timestamptz not null default now(),
  primary key (job_id, snow_date),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade
);
create index snow_events_company_idx on public.snow_events (company_id, snow_date desc);
select private.apply_policies('snow_events', '{owner,admin,office}', '{owner,admin,office}');

create table public.snow_visits (
  company_id uuid not null,
  visit_id uuid primary key,
  job_id uuid not null,
  snow_date date not null,
  foreign key (company_id, visit_id) references public.visits (company_id, id) on delete cascade,
  foreign key (job_id, snow_date) references public.snow_events (job_id, snow_date) on delete cascade
);
create index snow_visits_event_idx on public.snow_visits (job_id, snow_date);
select private.apply_policies('snow_visits', '{owner,admin,office}', '{owner,admin,office}');

-- What one visit bills, in place of the job's lines: null for an ordinary visit. The office's to set
-- (and the server's); a crew or a sub working the visit can't.
alter table public.visits
  add column price numeric(12, 2) check (price >= 0),
  add column price_note text check (length(price_note) <= 200);

create function private.visit_price_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null and not private.has_role(new.company_id, '{owner,admin,office}')
     and ((tg_op = 'INSERT' and (new.price is not null or new.price_note is not null))
       or (tg_op = 'UPDATE' and (new.price is distinct from old.price or new.price_note is distinct from old.price_note))) then
    raise exception 'Only the office sets what a visit bills.' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function private.visit_price_guard() from public;
create trigger visit_price_guard before insert or update of price, price_note on public.visits
  for each row execute function private.visit_price_guard();

-- A storm's visits take its price: the tier for what fell (what was forecast, until that's known) on
-- the first visit, and nothing more for the pushes after it. A customer with no tiers bills each push
-- the job's lines, as any visit does. Visits already invoiced stay as they were billed.
create function private.snow_price(p_job uuid, p_date date) returns void
language plpgsql security definer set search_path = '' as $$
declare v_tiers jsonb; v_depth numeric; v_price numeric; v_first uuid;
begin
  select s.tiers, coalesce(e.actual_in, e.forecast_in) into v_tiers, v_depth
    from public.snow_events e join public.snow_sites s on s.job_id = e.job_id
   where e.job_id = p_job and e.snow_date = p_date;
  if not found or v_depth is null or jsonb_array_length(v_tiers) = 0 then return; end if;
  -- The first tier it fits under; past them all, the last one.
  select (t ->> 'price')::numeric into v_price
    from jsonb_array_elements(v_tiers) t
   order by (t ->> 'up_to_in' is null or (t ->> 'up_to_in')::numeric >= v_depth) desc,
            case when t ->> 'up_to_in' is null or (t ->> 'up_to_in')::numeric >= v_depth then (t ->> 'up_to_in')::numeric end asc nulls last,
            (t ->> 'up_to_in')::numeric desc nulls last
   limit 1;
  select v.id into v_first
    from public.snow_visits sv join public.visits v on v.id = sv.visit_id
   where sv.job_id = p_job and sv.snow_date = p_date and v.status <> 'cancelled'
   order by v.created_at, v.title, v.id limit 1; -- made together, they're a moment apart at most: "push 1 of 3" first
  update public.visits v
     set price = case when v.id = v_first then v_price else 0 end,
         price_note = case when v.id = v_first then trim(to_char(v_depth, 'FM990.0')) || ' in of snow' else 'Included in the storm''s price' end
    from public.snow_visits sv
   where sv.visit_id = v.id and sv.job_id = p_job and sv.snow_date = p_date and v.invoice_id is null and v.status <> 'cancelled';
end $$;
revoke all on function private.snow_price(uuid, date) from public;

-- What fell is news to the price: when the estimate comes in, or the office writes its own.
create function private.snow_event_priced() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.actual_in is distinct from old.actual_in and (select auth.uid()) is not null then
    new.actual_by := (select auth.uid());
  end if;
  return new;
end $$;
create function private.snow_event_reprice() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.snow_price(new.job_id, new.snow_date);
  return null;
end $$;
revoke all on function private.snow_event_priced(), private.snow_event_reprice() from public;
create trigger written_by before update of actual_in on public.snow_events
  for each row execute function private.snow_event_priced();
create trigger reprice after update of actual_in, forecast_in on public.snow_events
  for each row execute function private.snow_event_reprice();

-- As 20261112000430_progress_tax_share.sql, except a visit with a price of its own bills that, as one
-- line, in place of the job's lines.
create or replace function public.create_invoice_for_job(p_job uuid, p_kind text default 'standard', p_amount numeric default null, p_month date default null)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  j public.jobs;
  v_invoice uuid;
  v_terms integer;
  v_tax numeric;
  v_today date;
  v_tz text;
  v_deposit numeric;
  v_amount numeric;
  v_contract numeric;
  v_prebilled numeric;
  v_existing bigint;
  v_month date := date_trunc('month', p_month::timestamp)::date;
  v_start date;
  v_end date;
  v_sort integer := 0;
  v_job_total numeric;
  v_job_taxable numeric;
  v_taxed numeric;
  v_was text := coalesce(current_setting('jobly.job_discounts', true), '');
  r record;
begin
  -- One invoice at a time for a job, so the checks below see each other's invoices.
  perform pg_advisory_xact_lock(hashtextextended('invoice-for-job:' || p_job::text, 0));
  select * into j from public.jobs where id = p_job;
  if not found then
    raise exception 'Job not found' using errcode = 'P0002';
  end if;
  if p_kind not in ('standard', 'deposit', 'progress', 'visits', 'retainage') then
    raise exception 'Unknown invoice type' using errcode = '22023';
  end if;
  select contract_total into v_contract from public.job_financials where job_id = j.id;
  select coalesce((settings ->> 'payment_terms_days')::integer, 30), coalesce((settings ->> 'default_tax_rate')::numeric, 0),
         (now() at time zone coalesce(timezone, 'UTC'))::date, coalesce(timezone, 'UTC')
    into v_terms, v_tax, v_today, v_tz
  from public.companies where id = j.company_id;
  -- The rate the client approved on the quote wins over the company default, which a job without
  -- a quote keeps.
  v_tax := coalesce((select q.tax_rate from public.quotes q where q.id = j.quote_id), v_tax, 0);

  if p_month is not null then
    if j.kind <> 'recurring' or p_kind not in ('standard', 'visits') then
      raise exception 'Only a recurring job''s visits or price are invoiced by the month' using errcode = '22023';
    end if;
    select x.period_start, x.period_end into v_start, v_end from public.invoice_reminders x where x.job_id = j.id and x.month = v_month;
    if not found then
      select x.period_start, x.period_end into v_start, v_end from private.invoice_period(j.invoice_day, v_month) x;
    end if;
    select number into v_existing from public.invoices
    where job_id = j.id and billing_month = v_month and status <> 'void' order by number limit 1;
    if found then
      raise exception 'This job already has its % invoice (#%)', to_char(v_month, 'FMMonth YYYY'), v_existing using errcode = '22023';
    end if;
  end if;

  select coalesce(sum(subtotal), 0) into v_prebilled
  from public.invoices where job_id = j.id and kind in ('deposit', 'progress') and status <> 'void';

  if p_kind = 'standard' and j.kind <> 'recurring' then
    select number into v_existing from public.invoices
    where job_id = j.id and kind = 'standard' and status <> 'void' order by number limit 1;
    if found then
      raise exception 'This job already has its final invoice (#%). Void it first to bill the job again', v_existing using errcode = '22023';
    end if;
  end if;

  if p_kind = 'visits' and not exists (
    select 1 from public.visits v where v.job_id = j.id and v.status = 'completed' and v.invoice_id is null and v.kind = 'job'
      and (p_month is null or private.visit_day(v.scheduled_on, v.completed_at, v_tz) between v_start and v_end)
  ) then
    if p_month is not null then
      raise exception 'There are no completed visits from % waiting to be invoiced', to_char(v_month, 'FMMonth') using errcode = '22023';
    end if;
    raise exception 'There are no completed visits waiting to be invoiced' using errcode = '22023';
  end if;

  if p_kind = 'deposit' then
    select deposit_amount into v_deposit from public.quotes where id = j.quote_id;
    v_amount := round(coalesce(p_amount, nullif(v_deposit, 0)), 2);
    if v_amount is null or v_amount <= 0 then
      raise exception 'Enter the deposit amount' using errcode = '22023';
    end if;
  elsif p_kind = 'progress' then
    if p_amount is null or p_amount <= 0 then
      raise exception 'Enter how much to bill' using errcode = '22023';
    end if;
    v_amount := round(p_amount, 2);
  elsif p_kind = 'retainage' then
    select coalesce(sum(retainage_amount), 0) into v_amount
    from public.invoices where job_id = j.id and kind <> 'retainage' and status <> 'void';
    v_amount := v_amount - coalesce((select sum(subtotal) from public.invoices where job_id = j.id and kind = 'retainage' and status <> 'void'), 0);
    if v_amount <= 0 then
      raise exception 'There''s no retainage left to bill on this job' using errcode = '22023';
    end if;
  end if;

  if p_kind in ('deposit', 'progress') and j.kind <> 'recurring' and v_prebilled + v_amount > coalesce(v_contract, 0) + 0.005 then
    raise exception 'That''s more than what''s left to bill on this job (%)',
      to_char(greatest(coalesce(v_contract, 0) - v_prebilled, 0), 'FM$999,999,990.00') using errcode = '22023';
  end if;

  insert into public.invoices (company_id, client_id, job_id, kind, subject, issued_on, due_on, tax_rate, retainage_pct, pay_app_number, billing_month)
  values (
    j.company_id, j.client_id, j.id, p_kind,
    case when p_month is not null then j.title || ' (' || to_char(v_month, 'FMMonth YYYY') || ')'
         else case p_kind when 'deposit' then 'Deposit: ' || j.title when 'visits' then j.title || ' (completed visits)'
                          when 'retainage' then 'Retainage: ' || j.title else j.title end end,
    v_today, v_today + v_terms,
    case when p_kind in ('deposit', 'retainage') then 0 else v_tax end,
    case when p_kind in ('standard', 'progress') then j.retainage_pct else 0 end,
    case when p_kind = 'progress' then (select coalesce(max(pay_app_number), 0) + 1 from public.invoices where job_id = j.id) end,
    v_month
  )
  returning id into v_invoice;

  -- All the lines go in first; the promo discounts are placed once they're there.
  perform set_config('jobly.job_discounts', 'on', true);

  if p_kind = 'deposit' then
    insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit, unit_price, taxable, sort)
    values (j.company_id, v_invoice, 'Deposit for ' || j.title, 1, 'ea', v_amount, false, 0);

  elsif p_kind = 'retainage' then
    insert into public.invoice_line_items (company_id, invoice_id, name, description, quantity, unit, unit_price, taxable, sort)
    values (j.company_id, v_invoice, 'Retainage release: ' || j.title, 'Amount held back on earlier invoices for this job', 1, 'ea', v_amount, false, 0);

  elsif p_kind = 'progress' then
    -- How much of what's billed is taxed (v_taxed): all of it on a fully taxable job (and on one
    -- with no priced lines to go by), as before. Otherwise the job's taxable share of it, and no
    -- more than the job's taxable work that earlier progress invoices haven't taxed already, so the
    -- final invoice's taxable amount never has to go below $0.
    select coalesce(sum(round(quantity * unit_price, 2)), 0), coalesce(sum(round(quantity * unit_price, 2)) filter (where taxable), 0)
      into v_job_total, v_job_taxable
    from public.job_line_items where job_id = j.id;
    if v_job_total <= 0 or v_job_taxable >= v_job_total then
      v_taxed := v_amount;
    else
      select coalesce(sum(round(l.quantity * l.unit_price, 2)), 0) into v_taxed
      from public.invoice_line_items l join public.invoices i on i.id = l.invoice_id
      where i.job_id = j.id and i.kind = 'progress' and i.status <> 'void' and l.taxable;
      v_taxed := greatest(least(round(v_amount * v_job_taxable / v_job_total, 2), v_job_taxable - v_taxed), 0);
    end if;
    if v_taxed >= v_amount or v_taxed <= 0 then
      insert into public.invoice_line_items (company_id, invoice_id, name, description, quantity, unit, unit_price, taxable, sort)
      values (j.company_id, v_invoice, 'Progress billing: ' || j.title,
              case when v_contract > 0 then round(v_amount / v_contract * 100, 1) || '% of the ' || to_char(v_contract, 'FM$999,999,990.00') || ' contract' end,
              1, 'ea', v_amount, v_taxed > 0, 0);
    else
      -- A line is taxed or it isn't, so a partly taxed amount is two lines.
      insert into public.invoice_line_items (company_id, invoice_id, name, description, quantity, unit, unit_price, taxable, sort)
      select j.company_id, v_invoice, 'Progress billing: ' || j.title,
             p.part || case when v_contract > 0 then ' of ' || round(v_amount / v_contract * 100, 1) || '% of the ' || to_char(v_contract, 'FM$999,999,990.00') || ' contract' else '' end,
             1, 'ea', p.amount, p.taxable, p.sort
      from (values ('Taxed part', v_taxed, true, 0), ('Untaxed part', v_amount - v_taxed, false, 1)) p (part, amount, taxable, sort);
    end if;

  elsif p_kind = 'visits' then
    for r in
      select v.id, v.price, v.price_note, coalesce(private.visit_day(null, v.completed_at, v_tz), v.scheduled_on) as day
      from public.visits v
      where v.job_id = j.id and v.status = 'completed' and v.invoice_id is null and v.kind = 'job'
        and (p_month is null or private.visit_day(v.scheduled_on, v.completed_at, v_tz) between v_start and v_end)
      order by coalesce(private.visit_day(null, v.completed_at, v_tz), v.scheduled_on)
    loop
      if r.price is not null then
        -- A visit with its own price (a snow storm billed by its depth) is one line at that price, as
        -- the job's first line is named and taxed, in place of the job's lines.
        insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort)
        select j.company_id, v_invoice, li.service_id, coalesce(li.name, j.title),
               'Visit on ' || to_char(r.day, 'Mon DD, YYYY') || coalesce(': ' || r.price_note, ''), 1, 'ea', r.price, coalesce(li.taxable, true), v_sort
        from (select 1) one
        left join lateral (select l.service_id, l.name, l.taxable from public.job_line_items l where l.job_id = j.id order by l.sort, l.id limit 1) li on true;
      else
        insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort, discount_quote_id)
        select j.company_id, v_invoice, li.service_id, li.name, 'Visit on ' || to_char(r.day, 'Mon DD, YYYY'), li.quantity, li.unit, li.unit_price, li.taxable, v_sort + li.sort, li.discount_key
        from public.job_line_items li where li.job_id = j.id and li.discount_billing is distinct from 'once';
      end if;
      update public.visits set invoice_id = v_invoice where id = r.id;
      v_sort := v_sort + 1000000;
    end loop;

  else
    insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort, discount_quote_id)
    select company_id, v_invoice, service_id, name, description, quantity, unit, unit_price, taxable, sort, discount_key
    from public.job_line_items where job_id = j.id and discount_billing is distinct from 'once';
    -- Credit what was already billed as deposits and progress payments (not on a month's invoice:
    -- it isn't the job's last).
    if p_month is null then
      -- A progress invoice's credit reduces the taxable amount by what that invoice's own lines
      -- taxed (t.taxed, between nothing and all of it): one taxed line when all of it was, as
      -- before, and a taxed and an untaxed line when part of it was. A deposit's is untaxed.
      insert into public.invoice_line_items (company_id, invoice_id, name, description, quantity, unit, unit_price, taxable, sort)
      select j.company_id, v_invoice,
             case i.kind when 'deposit' then 'Less deposit (invoice #' || i.number || ')' else 'Less progress billing (invoice #' || i.number || ')' end,
             case when t.taxed > 0 and t.taxed < i.subtotal then case when p.taxable then 'Taxed part' else 'Untaxed part' end end,
             1, 'ea', -p.amount, p.taxable, 200000 + row_number() over (order by i.number, p.taxable desc)
      from public.invoices i
      cross join lateral (
        select case when i.kind <> 'progress' then 0
                    when i.subtotal <= 0 then i.subtotal
                    else least(greatest(coalesce((select sum(round(l.quantity * l.unit_price, 2)) from public.invoice_line_items l
                                                   where l.invoice_id = i.id and l.taxable), 0), 0), i.subtotal) end as taxed
      ) t
      cross join lateral (values (true, t.taxed), (false, i.subtotal - t.taxed)) p (taxable, amount)
      where i.job_id = j.id and i.kind in ('deposit', 'progress') and i.status <> 'void' and i.id <> v_invoice
        -- An invoice that comes to $0 keeps its one $0 line, as before.
        and (p.amount <> 0 or (i.subtotal = 0 and p.taxable = (i.kind = 'progress')));
    end if;
  end if;

  if p_kind in ('standard', 'visits') then
    perform private.place_job_discounts(j.id);
    perform private.fit_job_discounts(v_invoice);
  end if;
  perform set_config('jobly.job_discounts', v_was, true);

  -- Touch the invoice so totals include the lines just added.
  update public.invoices set updated_at = now() where id = v_invoice;

  if j.status = 'requires_invoicing' and p_kind in ('standard', 'visits') then
    update public.jobs set status = 'completed' where id = j.id;
  end if;
  return v_invoice;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Who's told, and whether they can go out
-- ---------------------------------------------------------------------------------------------

-- Who's told about each of these snow jobs: the crew's lead and members (an active crew) and the
-- people listed on it, while they're still on the team (or a sub the office hasn't turned off), as
-- private.notify_schedule picks them; and, with office set, the people who schedule the whole team
-- (private.schedule_office), who hear about every one. Only the server asks.
create function public.snow_recipients(p_jobs uuid[]) returns table (job_id uuid, user_id uuid, office boolean)
language sql stable security definer set search_path = '' as $$
  with people as (
    select j.id as job_id, j.company_id, c.lead_user_id as user_id
      from public.jobs j join public.crews c on c.id = j.default_crew_id and c.active
     where j.id = any (p_jobs)
    union
    select j.id, j.company_id, cm.user_id
      from public.jobs j join public.crews c on c.id = j.default_crew_id and c.active
      join public.crew_members cm on cm.crew_id = c.id
     where j.id = any (p_jobs)
    union
    select p.job_id, p.company_id, p.user_id from public.snow_site_people p where p.job_id = any (p_jobs)
  )
  select p.job_id, p.user_id, false
    from people p join public.memberships m on m.company_id = p.company_id and m.user_id = p.user_id and m.active
   where m.role <> 'subcontractor'
      or exists (select 1 from public.subcontractors s where s.company_id = m.company_id and s.id = m.subcontractor_id and s.active)
  union all
  select j.id, o, true from public.jobs j cross join lateral private.schedule_office(j.company_id) o where j.id = any (p_jobs)
$$;
revoke execute on function public.snow_recipients(uuid[]) from public, anon, authenticated;
grant execute on function public.snow_recipients(uuid[]) to service_role;

-- The people asked whether they can go out on a snow day (the server asks the subcontractors it
-- tells: the business's own people are told, not asked), and what each said: null until they answer. Each person sees and answers their own
-- (snow_answer, from My day); the office sees everyone's.
create table public.snow_availability (
  company_id uuid not null,
  snow_date date not null,
  user_id uuid not null,
  can boolean,
  asked_at timestamptz not null default now(),
  answered_at timestamptz,
  primary key (company_id, snow_date, user_id),
  foreign key (company_id, user_id) references public.memberships (company_id, user_id) on delete cascade
);
alter table public.snow_availability enable row level security;
create policy snow_availability_read on public.snow_availability for select to authenticated
  using (user_id = (select auth.uid()) or private.has_role(company_id, '{owner,admin,office}'));

-- I can go out that day, or I can't. A no is news for the people who schedule the team.
create function public.snow_answer(p_company uuid, p_date date, p_can boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_was boolean; v_name text;
begin
  if p_can is null then raise exception 'Say yes or no.' using errcode = '22023'; end if;
  select can into v_was from public.snow_availability
   where company_id = p_company and snow_date = p_date and user_id = (select auth.uid()) for update;
  if not found then raise exception 'Nobody asked you about that day.' using errcode = '42501'; end if;
  update public.snow_availability set can = p_can, answered_at = now()
   where company_id = p_company and snow_date = p_date and user_id = (select auth.uid());
  if not p_can and v_was is distinct from false then
    select coalesce(nullif(trim(full_name), ''), 'Someone') into v_name from public.profiles where user_id = (select auth.uid());
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    select p_company, o, 'snow', left(coalesce(v_name, 'Someone') || ' can''t go out for snow on ' || to_char(p_date, 'Dy, Mon FMDD'), 300),
           'They answered no on My day. Their snow customers are on the Snow page.', '/snow'
      from private.schedule_office(p_company) o where o <> (select auth.uid());
  end if;
  return p_can;
end $$;
revoke execute on function public.snow_answer(uuid, date, boolean) from public, anon;
grant execute on function public.snow_answer(uuid, date, boolean) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Scheduling a storm
-- ---------------------------------------------------------------------------------------------

-- Schedule them, on the Snow page: for each snow job in p_plan ([{job_id, inches, pushes, kind}], as
-- the server worked it out from the forecast), the storm goes in the log and the job gets its visits
-- for p_date, as many as its pushes, less what it has that day already: with the job's crew, its
-- service level in the notes, and on them the crew and the people listed (snow_recipients), so each is
-- told they're on it and a sub sees it on their day. All at once or not at all, and asking twice never
-- doubles a visit. A customer who's told hears it's coming. Returns how many visits were made. For
-- the people who schedule the whole team.
create function public.snow_schedule(p_company uuid, p_date date, p_plan jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  p record; s public.snow_sites; j public.jobs;
  v_has integer; v_pushes integer; v_visit uuid; v_made integer := 0; v_first boolean;
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'schedule')) then
    raise exception 'Your role can''t schedule the whole team.' using errcode = '42501';
  end if;
  if p_date is null or p_date < private.company_today(p_company) then
    raise exception 'Pick today or a later day.' using errcode = '22023';
  end if;
  if jsonb_typeof(p_plan) is distinct from 'array' or jsonb_array_length(p_plan) > 1000 then
    raise exception 'Say which snow customers to schedule.' using errcode = '22023';
  end if;
  for p in
    select (x ->> 'job_id')::uuid as job_id, (x ->> 'inches')::numeric as inches,
           least(12, greatest(1, coalesce((x ->> 'pushes')::integer, 1))) as pushes,
           case when x ->> 'kind' = 'salt' then 'salt' else 'plow' end as kind
      from jsonb_array_elements(p_plan) x
  loop
    select * into s from public.snow_sites where job_id = p.job_id and company_id = p_company;
    continue when not found;
    select * into j from public.jobs where id = p.job_id and company_id = p_company and status = 'active';
    continue when not found;
    v_first := not exists (select 1 from public.snow_visits where job_id = p.job_id and snow_date = p_date);
    insert into public.snow_events (company_id, job_id, snow_date, kind, forecast_in, pushes)
    values (p_company, p.job_id, p_date, p.kind, p.inches, p.pushes)
    on conflict (job_id, snow_date) do update
      set forecast_in = coalesce(excluded.forecast_in, public.snow_events.forecast_in),
          pushes = greatest(public.snow_events.pushes, excluded.pushes),
          kind = case when excluded.kind = 'plow' then 'plow' else public.snow_events.kind end
    returning pushes into v_pushes;
    -- What it has that day already: the storm's own visits, or one somebody made by hand.
    select greatest(
        (select count(*) from public.snow_visits sv join public.visits v on v.id = sv.visit_id
          where sv.job_id = p.job_id and sv.snow_date = p_date and v.status <> 'cancelled'),
        (select least(1, count(*)) from public.visits v where v.job_id = p.job_id and v.scheduled_on = p_date and v.status <> 'cancelled'))
      into v_has;
    for n in v_has + 1 .. v_pushes loop
      insert into public.visits (company_id, job_id, property_id, title, scheduled_on, crew_id, notes)
      values (p_company, j.id, j.property_id,
              left(case p.kind when 'salt' then 'Salt: ' else '' end || j.title || case when v_pushes > 1 then format(' (push %s of %s)', n, v_pushes) else '' end, 200),
              p_date, j.default_crew_id,
              nullif(concat_ws(E'\n',
                case when s.clear_by is not null then 'Clear by ' || trim(to_char(s.clear_by, 'FMHH12:MI AM')) end,
                case s.priority when 1 then 'First priority' when 3 then 'After the others' end), ''))
      returning id into v_visit;
      insert into public.snow_visits (company_id, visit_id, job_id, snow_date) values (p_company, v_visit, j.id, p_date);
      insert into public.visit_assignees (company_id, visit_id, user_id)
      select p_company, v_visit, r.user_id from public.snow_recipients(array[j.id]) r where not r.office;
      if v_first and s.tell_client and n = v_has + 1 then
        perform private.emit(p_company, 'snow.scheduled', 'visit', v_visit, 'Snow service scheduled: ' || j.title,
          jsonb_build_object('client_id', j.client_id, 'kind', p.kind));
      end if;
      v_made := v_made + 1;
    end loop;
    perform private.snow_price(p.job_id, p_date);
  end loop;
  return v_made;
end $$;
revoke execute on function public.snow_schedule(uuid, date, jsonb) from public, anon;
grant execute on function public.snow_schedule(uuid, date, jsonb) to authenticated;

-- A storm's visit done is news for a customer who's told: an event the Automations rules below turn
-- into a message (visit.completed goes out too, for whatever rules listen to every visit).
create function private.snow_visit_done() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_job uuid; v_client uuid;
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    select sv.job_id into v_job from public.snow_visits sv join public.snow_sites s on s.job_id = sv.job_id and s.tell_client
     where sv.visit_id = new.id;
    if found then
      select client_id into v_client from public.jobs where id = v_job;
      perform private.emit(new.company_id, 'snow.completed', 'visit', new.id, 'Snow service done: ' || new.title, jsonb_build_object('client_id', v_client));
    end if;
  end if;
  return null;
end $$;
revoke all on function private.snow_visit_done() from public;
create trigger snow_visit_done after update of status on public.visits
  for each row execute function private.snow_visit_done();

-- The two messages a snow customer who's told gets, as Automations rules the business can reword or
-- turn off: made when Snow is installed, once, and left as the business has them after that.
create function private.install_snow_automations(p_company uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.automation_rules (company_id, template_key, name, description, trigger, delay_minutes, conditions, actions, enabled)
  values
    (p_company, 'snow_scheduled', 'Tell snow customers when we''re coming',
     'For snow customers set to be told, when their storm is scheduled.', 'snow.scheduled', 0, '[]',
     jsonb_build_array(jsonb_build_object('type', 'send_email',
       'subject', 'Snow is on the way: {{company.name}} is scheduled for {{date}}',
       'body', E'Hi {{client.first_name}},\n\nSnow is in the forecast, and {{company.name}} is scheduled to take care of {{address}} on {{date}}.\n\nQuestions? Reply to this email or call {{company.phone}}.')), true),
    (p_company, 'snow_completed', 'Tell snow customers when it''s done',
     'For snow customers set to be told, each time a snow visit is completed.', 'snow.completed', 0, '[]',
     jsonb_build_array(jsonb_build_object('type', 'send_email',
       'subject', '{{company.name}} has cleared {{address}}',
       'body', E'Hi {{client.first_name}},\n\n{{company.name}} has finished snow service at {{address}}.\n\nQuestions? Reply to this email or call {{company.phone}}.')), true)
  on conflict (company_id, template_key) do nothing
$$;
revoke all on function private.install_snow_automations(uuid) from public;

-- ---------------------------------------------------------------------------------------------
-- The app's switch, and the forecast source
-- ---------------------------------------------------------------------------------------------

-- As 20261103000500_paving_roofing_apps.sql, with Snow, whose starter messages come with it.
create or replace function public.trade_app_set_enabled(p_company uuid, p_app text, p_enabled boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_key text := case p_app when 'paving' then 'paving_app' when 'roofing' then 'roofing_app' when 'snow' then 'snow_app' end;
begin
  if v_key is null then
    raise exception 'There''s no app called %', p_app using errcode = '22023';
  end if;
  if not (private.has_role(p_company, '{owner,admin}') and private.has_perm(p_company, 'apps')) then
    raise exception 'Only owners and admins who connect apps can install %', initcap(p_app) using errcode = '42501';
  end if;
  update public.companies
     set settings = jsonb_set(coalesce(settings, '{}'), array[v_key],
       (case when jsonb_typeof(settings -> v_key) = 'object' then settings -> v_key else '{}'::jsonb end)
         || jsonb_build_object('enabled', p_enabled, 'changed_at', now()))
   where id = p_company;
  if p_app = 'snow' and p_enabled then perform private.install_snow_automations(p_company); end if;
  return p_enabled;
end $$;

-- Where the business's forecasts come from (Settings → Weather rules), for weather holds and Snow
-- alike: 'nws' (the US National Weather Service, where every business starts: a business with no
-- choice on file gets it, and Open-Meteo's forecast for a property outside the United States),
-- 'open_meteo' (the free service, which its terms keep to non-commercial use) or
-- 'open_meteo_commercial' (with the business's own paid key, once Apps → Open-Meteo has one). Set
-- like the weather rules: by the office with the Settings area.
create function public.set_weather_source(p_company uuid, p_source text) returns text
language plpgsql security definer set search_path = '' as $$
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'settings')) then
    raise exception 'Your role can''t change where forecasts come from.' using errcode = '42501';
  end if;
  if p_source is null or p_source not in ('open_meteo', 'open_meteo_commercial', 'nws') then
    raise exception 'Pick Open-Meteo or the National Weather Service.' using errcode = '22023';
  end if;
  if p_source = 'open_meteo_commercial' and not exists (
    select 1 from public.integrations where company_id = p_company and provider = 'open_meteo' and status = 'connected') then
    raise exception 'Add your Open-Meteo key on the Apps page first.' using errcode = '22023';
  end if;
  update public.companies set settings = jsonb_set(coalesce(settings, '{}'), '{weather_source}', to_jsonb(p_source)) where id = p_company;
  return p_source;
end $$;
revoke execute on function public.set_weather_source(uuid, text) from public, anon;
grant execute on function public.set_weather_source(uuid, text) to authenticated;

-- As 20261112000500_settings_and_removed_members.sql, with snow_app among the apps and the forecast
-- source among what the settings area decides.
create or replace function private.company_settings_area_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_gate record;
  v_key text;
begin
  if (select auth.uid()) is null or new.settings is not distinct from old.settings then
    return new;
  end if;
  for v_gate in
    select * from (values
      ('apps', array['careers', 'drive', 'paving_app', 'roofing_app', 'snow_app', 'team_chat', 'website_analytics', 'website_forms']),
      ('settings', array['weather_rules', 'weather_source']),
      ('subs', array['subs'])) g(area, keys)
  loop
    continue when private.has_perm(new.id, v_gate.area);
    foreach v_key in array v_gate.keys loop
      if new.settings -> v_key is distinct from old.settings -> v_key then
        new.settings := case when old.settings -> v_key is null then coalesce(new.settings, '{}') - v_key
          else jsonb_set(coalesce(new.settings, '{}'), array[v_key], old.settings -> v_key) end;
      end if;
    end loop;
  end loop;
  return new;
end $$;


select private.fold_member_checks('public.snow_sites');
select private.fold_member_checks('public.snow_site_people');
select private.fold_member_checks('public.snow_events');
select private.fold_member_checks('public.snow_visits');
select private.fold_member_checks('public.snow_availability');

notify pgrst, 'reload schema';
