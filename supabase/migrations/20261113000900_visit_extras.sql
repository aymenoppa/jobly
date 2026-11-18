-- Extra work on one visit of a repeating job, billed once.
--
-- A repeating job's lines bill on every visit (or every month), so mulch, an aeration, a storm
-- cleanup or an extra trim done once had nowhere to go: the crew was told to write it in the notes
-- (add_field_line refused a repeating job), and the office made a separate one-off job or typed a
-- line onto a draft invoice. Now extra work is put on the visit it's done on:
--
--   visit_extras        a line for one visit of a repeating job: what, how many, at what price. It
--                       isn't a job line, so the job's price for a visit, its contract total and
--                       everything that reads job_line_items are as they were. (A table of its own
--                       rather than a column on job_line_items: for a while after an update the
--                       previous app and server run against this database, and they'd count such a
--                       line in the job's price, bill it on every visit and write it back as an
--                       ordinary line. They never read this table, so they can't mistake it.)
--   Who adds one        the office (owners, admins, office, estimators: the people who write job
--                       lines), with a price; and the crew on the visit through add_field_line, by
--                       price list item and quantity at the office's price, which they never see.
--                       Crew-added ones say who and when (added_in_field_by, added_in_field_at),
--                       as crew-added job lines do, for the office to look over.
--   When it's billed    once, on the invoice that bills its visit (create_invoice_for_job), and only
--                       when the visit is completed:
--                         a job billed by the visit: with its visit, on the visit's invoice (after
--                           each visit, the month's, or the next one made as needed);
--                         a fixed-price job: on its next invoice (a month's: for visits up to the
--                           end of that month's days), as an addition to the price.
--                       visit_extras.invoice_id says which invoice. Voiding that invoice, or
--                       deleting it as a draft, frees the extra as it frees visits, so the invoice
--                       made in its place bills it again; nothing else can clear it, and nothing
--                       but create_invoice_for_job can set it, so it's never billed twice.
--   Not billed          while its visit isn't done. If the visit is cancelled, or deleted (the
--                       extra stays, with the day the visit was for in visit_was_on), the office
--                       with invoices is told on the bell, and the job's page lists it until it's
--                       put on another visit or removed. A visit with extra work on it stays on the
--                       schedule when the job's repeat changes or the job is closed, like one with
--                       work logged (private.job_waiting_visits; the server's materializeJob).
--   Autopay             an invoice with extra work on it is never charged without the office's OK:
--                       the charge waits ("Includes extra work added to a visit") until Approve
--                       charge, and the company's limit still applies after that (autopay_bill).
--   Tax and discounts   an extra is a line on the invoice like any other: taxed by its own taxable
--                       switch at the invoice's rate, counted by a promo code put on the invoice
--                       and by the minimum charge. A job's once-per-job discount is still its own
--                       amount, placed once (place_job_discounts): an extra only gives it room.
--
-- supabase/tests/visit_extras_test.sql covers it.

create table public.visit_extras (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  job_id uuid not null,
  -- Null once its visit has been deleted (visit_was_on keeps the day).
  visit_id uuid,
  service_id uuid,
  name text not null check (length(btrim(name)) > 0),
  description text,
  quantity numeric(14, 3) not null default 1 check (quantity > 0 and quantity <= 100000),
  unit text not null default 'ea',
  unit_price numeric(12, 2) not null default 0,
  unit_cost numeric(12, 2),
  unit_labor_cost numeric(12, 2) check (unit_labor_cost >= 0),
  taxable boolean not null default true,
  invoice_id uuid,
  visit_was_on date,
  added_in_field_by uuid references auth.users (id) on delete set null,
  added_in_field_at timestamptz,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade,
  foreign key (company_id, visit_id) references public.visits (company_id, id) on delete set null (visit_id),
  foreign key (company_id, service_id) references public.services (company_id, id) on delete set null (service_id),
  foreign key (company_id, invoice_id) references public.invoices (company_id, id) on delete set null (invoice_id)
);
comment on table public.visit_extras is 'Extra work on one visit of a repeating job, billed once with that visit (create_invoice_for_job). Not a job line: the job''s price is unchanged.';
comment on column public.visit_extras.invoice_id is 'The invoice that bills it, set by create_invoice_for_job alone. Null until then, and again when that invoice is voided or deleted.';
comment on column public.visit_extras.visit_was_on is 'The day of the visit it was on, kept when that visit is deleted (visit_id is null then). It isn''t billed until it''s put on another visit.';
comment on column public.visit_extras.added_in_field_at is 'When the crew added it on site (add_field_line), for the office to review. Null for the office''s own.';
create index visit_extras_job_idx on public.visit_extras (job_id);
create index visit_extras_visit_idx on public.visit_extras (visit_id) where visit_id is not null;
create index visit_extras_invoice_idx on public.visit_extras (invoice_id) where invoice_id is not null;

-- They carry prices, so they're the office's and the estimators', as job lines are
-- (20261017001200_crew_job_privacy.sql). The crew reads theirs, without prices, from
-- visit_extra_scope and adds through add_field_line.
select private.apply_policies('visit_extras', '{owner,admin,office,estimator}', '{owner,admin,office,estimator}');
revoke all on public.visit_extras from anon;
revoke truncate on public.visit_extras from authenticated;
create trigger touch_updated_at before update on public.visit_extras for each row execute function private.touch_updated_at();
-- Its cost comes from the price list as a job line's does: the labor in it, and the cost itself when
-- whoever adds it isn't shown costs (20261025003004_job_labor_costs.sql, 20261112000420_rates_behind_job_costs.sql).
create trigger labor_cost before insert on public.visit_extras for each row execute function private.job_line_labor();
create trigger price_list_cost before insert on public.visit_extras for each row execute function private.line_cost_from_price_list();

-- What may be written, whoever writes it (the office through the Data API, an assistant, the
-- server). jobly.visit_extras says when the database itself is writing: 'billing' while
-- create_invoice_for_job puts extras on an invoice, 'field' while add_field_line adds the crew's.
create function private.visit_extras_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v public.visits;
  j public.jobs;
  v_number bigint;
  v_mode text := coalesce(current_setting('jobly.visit_extras', true), '');
begin
  if tg_op = 'DELETE' then
    -- On an invoice, it stays on record. (When its whole job is being deleted, it goes with it.)
    if old.invoice_id is not null and exists (select 1 from public.jobs where id = old.job_id) then
      select i.number into v_number from public.invoices i where i.id = old.invoice_id and i.status <> 'void';
      if found then
        raise exception 'This extra work is on invoice #%. Void the invoice to take it off', v_number using errcode = '22023';
      end if;
    end if;
    return old;
  end if;

  if tg_op = 'INSERT' then
    new.invoice_id := null;
    new.visit_was_on := null;
    new.created_by := coalesce((select auth.uid()), new.created_by);
    if v_mode <> 'field' then
      new.added_in_field_by := null;
      new.added_in_field_at := null;
    end if;
  else
    if new.company_id is distinct from old.company_id or new.job_id is distinct from old.job_id then
      raise exception 'Extra work stays with its job' using errcode = '22023';
    end if;
    -- Who added it on site, and when, is said once.
    new.added_in_field_at := old.added_in_field_at;
    if new.added_in_field_by is not null then new.added_in_field_by := old.added_in_field_by; end if;

    -- The invoice that bills it: set only as the invoice is made, cleared only once that invoice is
    -- void or gone (release_visit_extras, or the draft deleted).
    if new.invoice_id is distinct from old.invoice_id then
      if new.invoice_id is not null and v_mode <> 'billing' then
        raise exception 'Extra work goes on an invoice when its visit is invoiced' using errcode = '22023';
      end if;
      if new.invoice_id is null then
        select i.number into v_number from public.invoices i where i.id = old.invoice_id and i.status <> 'void';
        if found then
          raise exception 'This extra work is on invoice #%. Void the invoice to bill it again', v_number using errcode = '22023';
        end if;
      end if;
    elsif old.invoice_id is not null
          and (new.name, new.description, new.quantity, new.unit, new.unit_price, new.taxable)
              is distinct from (old.name, old.description, old.quantity, old.unit, old.unit_price, old.taxable) then
      select i.number into v_number from public.invoices i where i.id = old.invoice_id;
      raise exception 'This extra work is on invoice #%. Change it on the invoice instead', v_number using errcode = '22023';
    end if;

    if new.visit_id is not distinct from old.visit_id then
      return new;
    end if;
    if new.visit_id is null then
      -- Only because its visit was deleted.
      if exists (select 1 from public.visits x where x.id = old.visit_id) then
        raise exception 'Extra work stays on a visit. Remove it, or put it on another visit' using errcode = '22023';
      end if;
      return new;
    end if;
    if new.invoice_id is not null then
      raise exception 'This extra work is already on an invoice, so it stays with its visit' using errcode = '22023';
    end if;
  end if;

  -- The visit it goes on (a new one, or one it's moved to): a visit of a repeating job that's still
  -- open, not cancelled and not invoiced yet.
  select * into v from public.visits where id = new.visit_id and company_id = new.company_id;
  if not found then
    raise exception 'That visit wasn''t found' using errcode = 'P0002';
  end if;
  if v.kind <> 'job' or v.job_id is null then
    raise exception 'Extra work goes on a visit for a job' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and v.job_id <> old.job_id then
    raise exception 'Extra work stays with its job. Put it on one of that job''s visits' using errcode = '22023';
  end if;
  select * into j from public.jobs where id = v.job_id;
  if j.kind <> 'recurring' then
    raise exception 'This job doesn''t repeat, so its work goes in the job''s line items' using errcode = '22023';
  end if;
  if j.status not in ('active', 'requires_invoicing') then
    raise exception 'This job is closed. Reopen it to add extra work' using errcode = '22023';
  end if;
  if v.status = 'cancelled' then
    raise exception 'This visit is cancelled. Put the extra work on another visit' using errcode = '22023';
  end if;
  if v.invoice_id is not null then
    raise exception 'This visit is already on invoice #%. Add the work to that invoice, or put it on another visit',
      (select i.number from public.invoices i where i.id = v.invoice_id) using errcode = '22023';
  end if;
  new.job_id := v.job_id;
  new.visit_was_on := null;
  return new;
end $$;
create trigger guard before insert or update or delete on public.visit_extras
  for each row execute function private.visit_extras_guard();

-- A voided invoice frees its extras, as it frees its visits (private.release_visits), so the invoice
-- made in its place bills them again. (A deleted draft frees them through invoice_id's foreign key.)
create function private.release_visit_extras() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'void' and old.status <> 'void' then
    update public.visit_extras set invoice_id = null where invoice_id = new.id;
  end if;
  return null;
end $$;
create trigger release_visit_extras after update on public.invoices
  for each row execute function private.release_visit_extras();

-- A visit cancelled or deleted with extra work on it that no invoice has: the work wasn't done, or
-- wasn't billed, and somebody asked for it. The extra stays (a deleted visit's keeps the day it was
-- for), the office with invoices hears once on the bell, and the job's page lists it until it's put
-- on another visit or removed. Not when the whole job is going. A problem here never stops the
-- visit from being cancelled or deleted (the schedule's own changes run through here too): it's
-- noted as a warning. Fires on every update, comparing the statuses itself
-- (20261017000700_status_triggers.sql explains why).
create function private.visit_extras_lose_visit() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_names text;
  v_job public.jobs;
  v_day date;
begin
  if tg_op = 'UPDATE' and not (new.status = 'cancelled' and old.status is distinct from 'cancelled') then
    return new;
  end if;
  begin
    select string_agg(e.name, ', ' order by e.created_at, e.id) into v_names
    from public.visit_extras e where e.visit_id = old.id and e.invoice_id is null;
    select coalesce(old.scheduled_on, (old.starts_at at time zone coalesce(c.timezone, 'UTC'))::date) into v_day
    from public.companies c where c.id = old.company_id;
    if tg_op = 'DELETE' then
      update public.visit_extras set visit_was_on = v_day where visit_id = old.id;
    end if;
    if v_names is not null then
      select * into v_job from public.jobs where id = old.job_id;
      if found then
        insert into public.notifications (company_id, user_id, kind, title, body, link)
        select old.company_id, u, 'invoice',
          left(format('Extra work wasn''t billed: its visit was %s', case when tg_op = 'DELETE' then 'removed' else 'cancelled' end), 300),
          left(format('%s, on %s%s. Put it on another visit from the job, or remove it.', v_names,
            coalesce(nullif(private.client_name(v_job.client_id), '') || ': ', '') || v_job.title,
            coalesce(', ' || to_char(v_day, 'FMMon FMDD'), '')), 1000),
          '/jobs/' || v_job.id
        from private.money_office(old.company_id) u;
      end if;
    end if;
  exception when others then
    raise warning 'extra work on a visit: %', sqlerrm;
  end;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
create trigger extras_lose_visit_deleted before delete on public.visits
  for each row execute function private.visit_extras_lose_visit();
create trigger extras_lose_visit_cancelled after update on public.visits
  for each row execute function private.visit_extras_lose_visit();

revoke all on function private.visit_extras_guard(), private.release_visit_extras(), private.visit_extras_lose_visit() from public;

/**
 * The extra work on a visit, without prices: what the crew is doing on it beyond the job's usual
 * work. For the people job_scope answers: crew leads and up, the crew on the job's visits, and a sub
 * on them.
 */
create function public.visit_extra_scope(p_visit uuid)
returns table (id uuid, name text, description text, quantity numeric, unit text, added_in_field boolean, invoiced boolean)
language sql stable security definer set search_path = '' as $$
  select e.id, e.name, e.description, e.quantity, e.unit, e.added_in_field_at is not null, e.invoice_id is not null
  from public.visit_extras e
  join public.jobs j on j.id = e.job_id
  where e.visit_id = p_visit
    and e.unit_price >= 0 -- money off is about money, not work, as in job_scope
    and (private.has_role(j.company_id, '{owner,admin,office,estimator,crew_lead}')
         or (private.is_member(j.company_id) and private.crew_sees_job(j.id))
         or (j.company_id = any (private.sub_companies()) and private.crew_sees_job(j.id)))
  order by e.created_at, e.id
$$;
revoke execute on function public.visit_extra_scope(uuid) from public, anon;
grant execute on function public.visit_extra_scope(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- The crew adds extra work on site
-- ---------------------------------------------------------------------------------------------

/**
 * As in 20261106000700_field_lines.sql, except on a repeating job: there the work goes on this
 * visit alone (visit_extras), billed once with it, where it used to be refused. On a one-off job it's
 * a line on the job, as before. Not once the visit is on an invoice: the office adds it there.
 *
 * Adds `p_quantity` of a price list item to the visit's job, at the item's price. For the team on
 * the visit (or crew leads and up). `p_id` is made on the phone, so a line sent again after no
 * signal is added once.
 */
create or replace function public.add_field_line(p_visit uuid, p_service uuid, p_quantity numeric, p_id uuid default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v public.visits;
  j public.jobs;
  s public.services;
  v_id uuid := coalesce(p_id, gen_random_uuid());
  v_was text := coalesce(current_setting('jobly.visit_extras', true), '');
begin
  select * into v from public.visits where id = p_visit;
  if not found or not private.is_member(v.company_id)
     or not (private.has_role(v.company_id, '{owner,admin,office,estimator,crew_lead}') or private.works_visit(v.id)) then
    raise exception 'That visit wasn''t found.' using errcode = 'P0002';
  end if;
  select * into j from public.jobs where id = v.job_id;
  if not found then
    raise exception 'This visit isn''t for a job.' using errcode = '22023';
  end if;
  if j.status not in ('active', 'requires_invoicing') or v.status = 'cancelled' then
    raise exception 'This job is closed. Tell the office about the extra work in the notes.' using errcode = '22023';
  end if;
  if j.kind = 'recurring' and v.invoice_id is not null and not exists (select 1 from public.visit_extras where id = v_id) then
    raise exception 'This visit is already invoiced. Tell the office about the extra work in the notes.' using errcode = '22023';
  end if;
  select * into s from public.services where id = p_service and company_id = j.company_id and active;
  if not found then
    raise exception 'That item isn''t on the price list anymore.' using errcode = 'P0002';
  end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity > 100000 then
    raise exception 'Enter how many.' using errcode = '22023';
  end if;

  if j.kind = 'recurring' then
    -- Sent again after no signal (even once its visit is invoiced), it's already there.
    if exists (select 1 from public.visit_extras where id = v_id) then
      return v_id;
    end if;
    perform set_config('jobly.visit_extras', 'field', true);
    insert into public.visit_extras (id, company_id, job_id, visit_id, service_id, name, description, quantity, unit, unit_price, unit_cost, taxable, added_in_field_by, added_in_field_at)
    values (v_id, j.company_id, j.id, v.id, s.id, s.name, s.description, round(p_quantity, 3), s.unit, s.unit_price, s.unit_cost, s.taxable,
            (select auth.uid()), now())
    on conflict (id) do nothing;
    perform set_config('jobly.visit_extras', v_was, true);
    return v_id;
  end if;

  insert into public.job_line_items (id, company_id, job_id, service_id, name, description, quantity, unit, unit_price, unit_cost, taxable, sort, added_in_field_by, added_in_field_at)
  values (v_id, j.company_id, j.id, s.id, s.name, s.description, round(p_quantity, 3), s.unit, s.unit_price, s.unit_cost, s.taxable,
          (select coalesce(max(sort), -1) + 1 from public.job_line_items where job_id = j.id and discount_key is null),
          (select auth.uid()), now())
  on conflict (id) do nothing;
  return v_id;
end $$;
revoke execute on function public.add_field_line(uuid, uuid, numeric, uuid) from public, anon;
grant execute on function public.add_field_line(uuid, uuid, numeric, uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Billing it
-- ---------------------------------------------------------------------------------------------

-- As in 20261113000400_visit_invoices_for_per_visit_jobs.sql, plus the extra work on the visits it
-- bills: a visits invoice puts each visit's extras after that visit's lines, and a fixed-price job's
-- invoice puts on the extras of its finished visits (a month's: up to the end of its days). Each
-- says the visit's date, and is marked with the invoice (visit_extras.invoice_id) so no other
-- invoice bills it. A job billed by the visit that's given a standard invoice keeps its extras for
-- the invoice that bills their visits.
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
  v_extras_was text := coalesce(current_setting('jobly.visit_extras', true), '');
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
  -- Visit by visit only for a job priced that way: anything else would bill the whole job once
  -- for each visit.
  if p_kind = 'visits' and j.kind = 'recurring' and j.pricing is not distinct from 'fixed' then
    raise exception 'This job is a fixed price, so it isn''t invoiced visit by visit. Invoice the job''s price instead' using errcode = '22023';
  elsif p_kind = 'visits' and j.kind <> 'recurring' and j.billing_mode is distinct from 'per_visit' then
    raise exception 'This job is billed as one job, not visit by visit. Make its final invoice instead' using errcode = '22023';
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
  -- Only here does extra work go on an invoice (private.visit_extras_guard).
  perform set_config('jobly.visit_extras', 'billing', true);

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
      select v.id, coalesce(private.visit_day(null, v.completed_at, v_tz), v.scheduled_on) as day
      from public.visits v
      where v.job_id = j.id and v.status = 'completed' and v.invoice_id is null and v.kind = 'job'
        and (p_month is null or private.visit_day(v.scheduled_on, v.completed_at, v_tz) between v_start and v_end)
      order by coalesce(private.visit_day(null, v.completed_at, v_tz), v.scheduled_on)
    loop
      insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort, discount_quote_id)
      select j.company_id, v_invoice, li.service_id, li.name, 'Visit on ' || to_char(r.day, 'Mon DD, YYYY'), li.quantity, li.unit, li.unit_price, li.taxable, v_sort + li.sort, li.discount_key
      from public.job_line_items li where li.job_id = j.id and li.discount_billing is distinct from 'once';
      update public.visits set invoice_id = v_invoice where id = r.id;
      -- Extra work on this visit alone: on its invoice once, after the visit's own lines.
      insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort)
      select j.company_id, v_invoice, e.service_id, e.name,
             concat_ws(E'\n', 'Extra work, visit on ' || to_char(r.day, 'Mon DD, YYYY'), nullif(btrim(e.description), '')),
             e.quantity, e.unit, e.unit_price, e.taxable, v_sort + 900000 + row_number() over (order by e.created_at, e.id)
      from public.visit_extras e where e.visit_id = r.id and e.invoice_id is null;
      update public.visit_extras set invoice_id = v_invoice where visit_id = r.id and invoice_id is null;
      v_sort := v_sort + 1000000;
    end loop;

  else
    insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort, discount_quote_id)
    select company_id, v_invoice, service_id, name, description, quantity, unit, unit_price, taxable, sort, discount_key
    from public.job_line_items where job_id = j.id and discount_billing is distinct from 'once';
    -- A fixed price is the price whatever the visits, so the extra work on its finished visits that
    -- no invoice has yet goes on this one, each once, as an addition to the price (a month's
    -- invoice: on visits up to the end of its days; later ones wait for their month's).
    if j.kind = 'recurring' and j.pricing is not distinct from 'fixed' then
      with billed as (
        update public.visit_extras e set invoice_id = v_invoice
        from public.visits v
        where e.job_id = j.id and e.invoice_id is null and v.id = e.visit_id and v.kind = 'job' and v.status = 'completed'
          and (p_month is null or private.visit_day(v.scheduled_on, v.completed_at, v_tz) <= v_end)
        returning e.id, e.service_id, e.name, e.description, e.quantity, e.unit, e.unit_price, e.taxable, e.created_at,
                  coalesce(private.visit_day(null, v.completed_at, v_tz), v.scheduled_on) as day
      )
      insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort)
      select j.company_id, v_invoice, b.service_id, b.name,
             concat_ws(E'\n', 'Extra work, visit on ' || to_char(b.day, 'Mon DD, YYYY'), nullif(btrim(b.description), '')),
             b.quantity, b.unit, b.unit_price, b.taxable, 100000 + row_number() over (order by b.day, b.created_at, b.id)
      from billed b;
    end if;
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
    -- A one-off job's final invoice bills the whole job, so the visits finished by now are on it.
    if j.kind <> 'recurring' then
      update public.visits set invoice_id = v_invoice
      where job_id = j.id and kind = 'job' and status = 'completed' and invoice_id is null;
    end if;
  end if;

  if p_kind in ('standard', 'visits') then
    perform private.place_job_discounts(j.id);
    perform private.fit_job_discounts(v_invoice);
  end if;
  perform set_config('jobly.job_discounts', v_was, true);
  perform set_config('jobly.visit_extras', v_extras_was, true);

  -- Touch the invoice so totals include the lines just added.
  update public.invoices set updated_at = now() where id = v_invoice;

  if j.status = 'requires_invoicing' and p_kind in ('standard', 'visits') then
    update public.jobs set status = 'completed' where id = j.id;
  end if;
  return v_invoice;
end $$;
revoke execute on function public.create_invoice_for_job(uuid, text, numeric, date) from public, anon;
grant execute on function public.create_invoice_for_job(uuid, text, numeric, date) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Autopay asks first
-- ---------------------------------------------------------------------------------------------

/**
 * As in 20261104000900_monthly_plan_autopay.sql, plus: an invoice with extra work on it (a visit's
 * extras, whoever added them) is more than the client's usual charge, so it waits for the office's
 * OK whatever the amount, once ("Includes extra work added to a visit"). Approved, it's charged
 * like any other, and the company's limit still holds it if it's over that and more than what was
 * approved.
 */
create or replace function public.autopay_bill(p_charge uuid, p_token uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r public.autopay_charges;
  j public.jobs;
  i public.invoices;
  m public.client_payment_methods;
  v_autopay jsonb;
  v_pm uuid;
  v_invoice uuid;
  v_accepted timestamptz;
  v_since timestamptz;
  v_begun timestamptz;
  v_reason text;
  v_max numeric;
begin
  select * into r from public.autopay_charges where id = p_charge for update;
  if not found or p_token is null or r.status <> 'charging' or r.claim_token is distinct from p_token then
    return jsonb_build_object('outcome', 'lost', 'reason', null, 'invoice_id', r.invoice_id);
  end if;

  -- 1. Billed already (a retry, an approved charge, or a manual one): what's become of the invoice.
  if r.invoice_id is not null then
    select * into i from public.invoices where id = r.invoice_id for update;
    if i.status = 'paid' then
      if private.autopay_paid_by_charge(i.id, r.created_at) then
        return private.autopay_bill_end(r.id, 'paid', null);   -- went through before its worker stopped
      end if;
      return private.autopay_bill_end(r.id, 'called_off', 'Paid another way');
    end if;
    -- Stripe credit paid its own Stripe invoice in full before it was marked sent (its worker stopped
    -- between): sent now, as finish_autopay_charge does, so invoice_totals makes it paid.
    if i.status = 'draft' and i.balance_due <= 0 and private.autopay_paid_by_charge(i.id, r.created_at) then
      update public.invoices set status = 'sent' where id = i.id and status = 'draft';
      -- Nothing on the card: a draft is only paid before /pay, so by credit.
      update public.autopay_charges set charged_amount = 0 where id = r.id;
      return private.autopay_bill_end(r.id, 'paid', null);
    end if;
    if i.status not in ('draft', 'sent', 'partially_paid', 'overdue') or i.balance_due <= 0 then
      return private.autopay_bill_end(r.id, 'called_off', case i.status when 'void' then 'The invoice was voided'
        when 'written_off' then 'The invoice was written off' else 'Nothing is owed on it' end);
    end if;
    -- Charge card is for the invoice as the office saw it.
    if r.source = 'manual' and i.client_id is distinct from r.client_id then
      return private.autopay_bill_end(r.id, 'called_off', 'The invoice is for another client now');
    end if;
    if r.source = 'manual' and i.balance_due > r.approved_amount then
      return private.autopay_bill_end(r.id, 'called_off', 'The invoice changed after Charge card was pressed. Charge it again');
    end if;
  elsif r.source = 'manual' then
    return private.autopay_bill_end(r.id, 'called_off', 'The invoice was deleted');
  end if;

  -- 2. Still on, on fresh data (the same checks billed or not; the status trigger tells the office
  -- when that leaves an invoice unpaid). A manual charge has no job or bill, so only the company's
  -- switch and the client's agreement apply to it.
  select * into j from public.jobs where id = r.job_id;
  select private.autopay_of(c.settings) into v_autopay from public.companies c where c.id = r.company_id;
  v_pm := private.autopay_ready(r.company_id, r.client_id);
  if r.source = 'autopay' and (j.id is null or not j.autopay or j.status = 'archived') then
    return private.autopay_bill_end(r.id, 'called_off', 'Autopay is off for this job');
  end if;
  if v_autopay -> 'enabled' is distinct from 'true'::jsonb then
    return private.autopay_bill_end(r.id, 'called_off', 'Autopay is turned off in Settings');
  end if;
  if v_pm is null then
    return private.autopay_bill_end(r.id, 'called_off', 'Autopay is off for this client');
  end if;
  if r.bill = 'standard' and r.invoice_id is null and j.status <> 'requires_invoicing' then
    return private.autopay_bill_end(r.id, 'called_off', 'The job isn''t waiting to be billed');
  end if;
  if r.bill = 'month' and r.invoice_id is null
     and not (j.kind = 'recurring' and j.status = 'active' and j.pricing is not distinct from 'fixed' and j.invoice_schedule is not distinct from 'monthly') then
    return private.autopay_bill_end(r.id, 'called_off', 'The job isn''t a monthly plan anymore');
  end if;
  if r.bill = 'visits' and r.invoice_id is not null
     and exists (select 1 from public.visits v where v.invoice_id = r.invoice_id and v.status <> 'completed') then
    return private.autopay_bill_end(r.id, 'called_off', 'A visit on it was reopened');
  end if;
  update public.autopay_charges set payment_method_id = v_pm where id = r.id;

  -- 3. No invoice yet: make it, as the office's Invoice button would (this runs as the function's
  -- owner, past row-level security). It bills every finished visit of the job not yet billed (a
  -- monthly plan: the month's price, once). Those that queued another of the job's charges still
  -- gathering visits (one made while this was claimed) count as queued for this one too: that
  -- charge has nothing left to bill.
  if r.invoice_id is null then
    begin
      v_invoice := case when r.bill = 'month' then public.create_invoice_for_job(r.job_id, 'standard', null, r.billing_month)
                        else public.create_invoice_for_job(r.job_id, r.bill) end;
    exception when sqlstate '22023' or sqlstate 'P0002' then
      return private.autopay_bill_end(r.id, 'called_off', left(sqlerrm, 1000));
    end;
    update public.autopay_charges a
    set invoice_id = v_invoice,
        visit_ids = a.visit_ids || array(
          select distinct x
          from public.autopay_charges o cross join lateral unnest(o.visit_ids) x
          join public.visits v on v.id = x and v.invoice_id = v_invoice
          where o.job_id = r.job_id and o.id <> r.id and o.status in ('waiting', 'charging') and o.invoice_id is null
            and x <> all (a.visit_ids))
    where a.id = r.id
    returning a.visit_ids into r.visit_ids;
    r.invoice_id := v_invoice;
  end if;
  select * into i from public.invoices where id = r.invoice_id for update;

  -- 4. Asking first, only while the invoice is still a draft, and only for autopay's own charges.
  -- Autopay charges without the office's OK only for visits it queued itself (visit_ids: finished
  -- while autopay was in force for the client and the job). A visit freed by a voided or deleted
  -- invoice, or finished while autopay was paused, off in Settings or off for the job, wasn't, so
  -- the bill waits for Approve charge. The dates are checked too, for a visit finished offline (or
  -- marked done later) before autopay started, or while it was paused, and queued when it synced (an
  -- offline Complete keeps its tap time as completed_at: visit_defaults, visit_sub_guard): from the
  -- start of the client's unbroken run of agreements (a card changed, revoked_via 'replaced',
  -- doesn't break it), from when the job's autopay went on, and from when the office last resumed it
  -- (resumed_at). A monthly plan's month is checked the same way from the day it began, and the
  -- client's agreement in force must mention a monthly plan.
  if i.status = 'draft' and r.source = 'autopay' then
    -- Work an AI assistant marked done (autopay_queue): the office looks first, whatever the amount.
    if r.held is not null and r.approved_at is null then
      update public.autopay_charges
      set status = 'needs_approval', last_error = r.held, claim_token = null, locked_until = null, busy_since = null
      where id = r.id;
      return jsonb_build_object('outcome', 'needs_approval', 'reason', r.held, 'invoice_id', i.id);
    end if;
    if r.bill in ('visits', 'month') and r.approved_at is null then
      select min(a.accepted_at) into v_accepted from public.autopay_authorizations a
      where a.company_id = r.company_id and a.client_id = r.client_id
        and a.accepted_at > coalesce((
          select max(b.revoked_at) from public.autopay_authorizations b
          where b.company_id = r.company_id and b.client_id = r.client_id and b.revoked_at is not null and b.revoked_via <> 'replaced'
        ), '-infinity'::timestamptz);
      select greatest(v_accepted, coalesce(j.autopay_since, '-infinity'::timestamptz), coalesce(a.resumed_at, '-infinity'::timestamptz))
      into v_since from public.autopay_authorizations a
      where a.company_id = r.company_id and a.client_id = r.client_id and a.revoked_at is null;
      if r.bill = 'month' then
        -- When the month began where the company is: the day after last month's invoice day.
        select coalesce(x.period_start, p.period_start)::timestamp at time zone coalesce(c.timezone, 'UTC') into v_begun
        from public.companies c
        cross join lateral private.invoice_period(j.invoice_day, r.billing_month) p
        left join public.invoice_reminders x on x.job_id = r.job_id and x.month = r.billing_month
        where c.id = r.company_id;
      end if;
      v_reason := case
        when r.bill = 'visits' and exists (select 1 from public.visits v where v.invoice_id = i.id and v.completed_at < v_since)
          then 'Includes visits from before autopay started'
        when r.bill = 'visits' and exists (select 1 from public.visits v where v.invoice_id = i.id and v.id <> all (r.visit_ids))
          then 'Includes visits autopay didn''t queue (finished while it was off, or from a voided invoice)'
        when r.bill = 'month' and v_begun < v_since
          then 'Covers days from before autopay started'
        when r.bill = 'month' and not exists (
            select 1 from public.autopay_authorizations a
            where a.company_id = r.company_id and a.client_id = r.client_id and a.revoked_at is null and private.autopay_covers_monthly(a.terms))
          then 'Their autopay terms don''t mention a monthly plan'
        -- More than the visit's (or the month's) usual price: the office looks before the card is charged.
        when exists (select 1 from public.visit_extras e where e.invoice_id = i.id)
          then 'Includes extra work added to a visit'
      end;
      if v_reason is not null then
        update public.autopay_charges
        set status = 'needs_approval', last_error = v_reason, claim_token = null, locked_until = null, busy_since = null
        where id = r.id;
        return jsonb_build_object('outcome', 'needs_approval', 'reason', v_reason, 'invoice_id', i.id);
      end if;
    end if;
    v_max := case when jsonb_typeof(v_autopay -> 'max_amount') = 'number' then (v_autopay -> 'max_amount')::numeric end;
    if v_max is not null and i.balance_due > v_max and (r.approved_at is null or i.balance_due > r.approved_amount) then
      update public.autopay_charges
      set status = 'needs_approval', last_error = null, claim_token = null, locked_until = null, busy_since = null,
          approved_at = null, approved_by = null, approved_amount = null
      where id = r.id;
      return jsonb_build_object('outcome', 'needs_approval', 'reason', null, 'invoice_id', i.id);
    end if;
  end if;

  -- 5. Charge it: the claim is held for the Stripe calls.
  update public.autopay_charges set locked_until = now() + interval '5 minutes' where id = r.id;
  select * into m from public.client_payment_methods where id = v_pm;
  return jsonb_build_object(
    'outcome', 'charge', 'invoice_id', i.id, 'invoice_status', i.status, 'balance_due', i.balance_due,
    'method', jsonb_build_object('id', m.id, 'stripe_payment_method_id', m.stripe_payment_method_id,
      'stripe_customer_id', m.stripe_customer_id, 'livemode', m.livemode, 'stripe_account', m.stripe_account, 'type', m.type));
end $$;

-- ---------------------------------------------------------------------------------------------
-- A visit with extra work on it stays on the schedule
-- ---------------------------------------------------------------------------------------------

-- As in 20261113000120_closed_jobs_leave_the_schedule.sql, plus: not a visit with extra work on it,
-- which somebody asked for on that day.
create or replace function private.job_waiting_visits(p_job uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select v.id
  from public.visits v
  where v.job_id = p_job and v.status = 'scheduled' and v.recurrence_key is not null
    and v.scheduled_on >= private.company_today(v.company_id)
    and not exists (select 1 from public.job_pay_visits pv join public.job_pay p on p.id = pv.job_pay_id
                    where pv.visit_id = v.id and p.status in ('done', 'paid'))
    and not exists (select 1 from public.time_entries t where t.visit_id = v.id)
    and not exists (select 1 from public.job_materials m where m.visit_id = v.id)
    and not exists (select 1 from public.checklist_responses r where r.visit_id = v.id)
    and not exists (select 1 from public.visit_extras e where e.visit_id = v.id)
$$;

-- ---------------------------------------------------------------------------------------------
-- AI assistants
-- ---------------------------------------------------------------------------------------------

-- As in 20261106000200_property_equipment.sql, plus a visit's extra work, which goes with jobs as
-- job lines do.
create or replace function private.assistant_table_area(p_table text) returns text
language sql immutable set search_path = '' as $$
  select case p_table
    when 'clients' then 'clients'
    when 'client_contacts' then 'clients'
    when 'properties' then 'clients'
    when 'property_access' then 'clients'
    when 'property_assets' then 'clients'
    when 'requests' then 'records'
    when 'messages' then 'records'
    when 'jobs' then 'jobs'
    when 'job_line_items' then 'jobs'
    when 'visit_extras' then 'jobs'
    when 'visits' then 'schedule'
    when 'visit_assignees' then 'schedule'
    when 'visit_equipment' then 'schedule'
    when 'routes' then 'schedule'
    when 'time_entries' then 'time'
    when 'quotes' then 'quotes'
    when 'quote_line_items' then 'quotes'
    when 'quote_options' then 'quotes'
    when 'invoices' then 'invoices'
    when 'invoice_line_items' then 'invoices'
    when 'payments' then 'invoices'
    when 'pay_periods' then 'pay'
    when 'pay_period_lines' then 'pay'
    when 'companies' then 'company'
    when 'services' then 'prices'
    when 'crews' then 'crews'
    when 'crew_members' then 'crews'
    when 'checklist_templates' then 'checklists'
    when 'intake_forms' then 'booking'
    when 'sop_pages' then 'guides'
    when 'sop_categories' then 'guides'
    when 'automation_rules' then 'automations'
    when 'memberships' then 'team'
    when 'company_roles' then 'team'
    when 'document_templates' then 'templates'
    when 'contract_sections' then 'templates'
    when 'campaigns' then 'marketing'
    when 'promo_codes' then 'promos'
  end
$$;

-- The table's policies check the company the per-row way; rewrite them like the others (see
-- 20261018000990_policy_lookups.sql).
select private.fold_member_checks('public.visit_extras');

notify pgrst, 'reload schema';
