-- A payment schedule's invoices are the payments the client signed, whatever its shape.
--
-- Until now a payment due at approval was a deposit invoice for its whole amount, tax and all, while
-- each later one was a progress invoice for its amount before tax, held to what was left of the
-- contract before tax. On a taxed quote with a deposit that left the last payment short and a final
-- invoice of $0 plus tax that nobody signed ($1,000 at 10%, half and half: $550, $495 and $55); three
-- equal taxed payments came to a cent under the quote; a schedule that didn't end with "when the work
-- is done" always needed a final invoice after its last payment; and one whose "when the work is
-- done" payment wasn't the last had that payment bill the later ones too.
--
-- Now there is one rule, the deposit's, for every payment:
--
--   Every payment but the last to be invoiced is an invoice on account for exactly the amount
--   signed, tax included, with no tax of its own: a deposit invoice for the payment due at approval
--   (as it always was), a progress invoice with one untaxed line for any other.
--
--   The last payment to be invoiced, whichever it is, is the job's final invoice: the job's lines,
--   less each payment before it, plus the tax on the whole job. So it comes to the quote's total
--   less the others, which is its own signed amount, and the tax across them is the quote's tax,
--   worked out once. Nothing is needed after it, and the job's last visit finishing closes the job
--   as it does any job that has its final invoice.
--
-- Worked: $1,000 of taxed work at 10% is $1,100, half at approval and half as the work starts.
-- Approval: deposit invoice, $550.00. The first visit starts: the final invoice, $1,000.00 of work,
-- less payment 1 of 2 $550.00, tax $100.00: $550.00. Two invoices, $1,100.00, tax $100.00.
--
-- The pieces:
--
--   create_invoice_for_job  Told which payment it's making (jobly.installment, set by
--                           private.make_installment), a progress invoice is on account: one untaxed
--                           line for the amount, held to what the job comes to with its tax rather
--                           than before it. The final invoice names the payments it takes off. And
--                           the job's own Invoice button (a standard invoice) on a job whose "when
--                           the work is done" payment has payments after it still to come makes that
--                           payment, on account, and leaves the later ones for their moment.
--   The final invoice       made any way (the button, autopay, by hand) is the invoice of every
--                           payment that has none: they read as on it, and voiding it frees them to
--                           be invoiced again by hand. Nothing is written on them to go stale.
--   Invoice now             works for the "when the work is done" payment too.
--   A finished job          whose payments were all invoiced before this (as progress invoices, with
--                           no final one) and that has nothing left to bill closes instead of asking
--                           for a $0 invoice.
--
-- Jobs part-way through a schedule: invoices already made stay as they are. The next payments follow
-- the rule above, and the last one, being the final invoice, takes off whatever was billed before it
-- however it was billed, so the job still comes to its total. Payments marked "The final invoice
-- (#N) bills it" become payments on that invoice.
--
-- supabase/tests/payment_shapes_test.sql runs the grid; payment_schedule_test.sql the rest.

-- ---------------------------------------------------------------------------------------------
-- What create_invoice_for_job needs to know about a job's payments (it runs as the person)
-- ---------------------------------------------------------------------------------------------

-- A job's payments that have no invoice, or only a void one.
create function private.unbilled_installments(p_job uuid) returns setof public.job_installments
language sql stable security definer set search_path = '' as $$
  select s.* from public.job_installments s
   where s.job_id = p_job
     and not exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status <> 'void')
$$;

-- The payment the job's Invoice button makes instead of a final invoice: the one due when the work
-- is done, while payments after it are still to come. Null when the final invoice is what's wanted.
create function private.installment_for_invoice(p_job uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select s.id from private.unbilled_installments(p_job) s
   where s.due = 'work_done'
     and exists (select 1 from private.unbilled_installments(p_job) x where x.position > s.position)
   limit 1
$$;

-- The payment the job's Deposit button makes: the one due at approval, while it has no invoice.
create function private.installment_for_deposit(p_job uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select s.id from private.unbilled_installments(p_job) s where s.due = 'approval' limit 1
$$;

-- A payment's name and amount, for the invoice that bills it.
create function private.installment_billing(p_installment uuid, out name text, out amount numeric, out job_id uuid)
language sql stable security definer set search_path = '' as $$
  select private.installment_name(s.position, s.count), s.amount, s.job_id from public.job_installments s where s.id = p_installment
$$;

-- "payment 2 of 3" for an invoice that bills one, as the final invoice names what it takes off.
create function private.installment_of_invoice(p_invoice uuid) returns text
language sql stable security definer set search_path = '' as $$
  select 'payment ' || s.position || ' of ' || s.count from public.job_installments s where s.invoice_id = p_invoice order by s.position limit 1
$$;

revoke all on function private.unbilled_installments(uuid), private.installment_for_invoice(uuid), private.installment_for_deposit(uuid),
  private.installment_billing(uuid), private.installment_of_invoice(uuid) from public;
grant execute on function private.installment_for_invoice(uuid), private.installment_for_deposit(uuid), private.installment_billing(uuid),
  private.installment_of_invoice(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- Making the invoice
-- ---------------------------------------------------------------------------------------------

-- As in 20261113000900_visit_extras.sql, plus a schedule's payments: see the top of this file.
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
  v_inst_was text := coalesce(current_setting('jobly.installment', true), '');
  v_inst uuid;
  v_inst_name text;
  v_inst_amount numeric;
  v_full numeric;
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
  -- A payment of the job's schedule: private.make_installment says which. Or the job's own Invoice
  -- button on a job whose "when the work is done" payment has others after it still to come: that
  -- payment is what's made, on account, and the later ones wait for their moment. Or its Deposit
  -- button, which makes the payment due at approval as it always did.
  v_inst := nullif(v_inst_was, '')::uuid;
  if v_inst is null and p_kind = 'standard' and p_month is null and j.kind <> 'recurring' then
    v_inst := private.installment_for_invoice(j.id);
    if v_inst is not null then
      p_kind := 'progress';
      p_amount := null;
    end if;
  elsif v_inst is null and p_kind = 'deposit' and j.kind <> 'recurring' then
    v_inst := private.installment_for_deposit(j.id);
  end if;
  if v_inst is not null then
    select b.name, b.amount into v_inst_name, v_inst_amount from private.installment_billing(v_inst) b where b.job_id = j.id;
    if not found then
      v_inst := null;
    elsif p_kind = 'progress' then
      p_amount := coalesce(p_amount, v_inst_amount);
    end if;
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

  -- A schedule's payment is part of the quote's total, tax and all, so it's held to what the job
  -- comes to with its tax (v_full); any other deposit or progress invoice to the contract before it.
  if v_inst is not null then
    select coalesce(v_contract, 0) + round(greatest(coalesce(sum(round(quantity * unit_price, 2)) filter (where taxable), 0), 0) * v_tax, 2)
      into v_full
    from public.job_line_items where job_id = j.id;
  end if;
  if p_kind in ('deposit', 'progress') and j.kind <> 'recurring' and v_prebilled + v_amount > coalesce(v_full, v_contract, 0) + 0.005 then
    raise exception 'That''s more than what''s left to bill on this job (%)',
      to_char(greatest(coalesce(v_full, v_contract, 0) - v_prebilled, 0), 'FM$999,999,990.00') using errcode = '22023';
  end if;

  -- The invoice is the payment's from the moment it exists (private.invoice_bills_installment).
  perform set_config('jobly.installment', coalesce(v_inst::text, ''), true);

  insert into public.invoices (company_id, client_id, job_id, kind, subject, issued_on, due_on, tax_rate, retainage_pct, pay_app_number, billing_month)
  values (
    j.company_id, j.client_id, j.id, p_kind,
    case when p_month is not null then j.title || ' (' || to_char(v_month, 'FMMonth YYYY') || ')'
         when v_inst is not null and p_kind <> 'deposit' then left(v_inst_name || ': ' || j.title, 200)
         else case p_kind when 'deposit' then 'Deposit: ' || j.title when 'visits' then j.title || ' (completed visits)'
                          when 'retainage' then 'Retainage: ' || j.title else j.title end end,
    v_today, v_today + v_terms,
    case when p_kind in ('deposit', 'retainage') then 0 else v_tax end,
    case when p_kind in ('standard', 'progress') then j.retainage_pct else 0 end,
    case when p_kind = 'progress' then (select coalesce(max(pay_app_number), 0) + 1 from public.invoices where job_id = j.id) end,
    v_month
  )
  returning id into v_invoice;
  perform set_config('jobly.installment', v_inst_was, true);

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

  elsif p_kind = 'progress' and v_inst is not null then
    -- A schedule's payment on account: the amount signed, tax included, so no tax of its own. The
    -- final invoice takes it off and carries the job's tax.
    insert into public.invoice_line_items (company_id, invoice_id, name, description, quantity, unit, unit_price, taxable, sort)
    values (j.company_id, v_invoice, v_inst_name || ' for ' || j.title,
            case when v_full > 0 then 'Part of the ' || to_char(v_full, 'FM$999,999,990.00') || ' total' || case when v_full > coalesce(v_contract, 0) then ', tax included' else '' end end,
            1, 'ea', v_amount, false, 0);

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
             case when n.payment is not null then 'Less ' || n.payment || ' (invoice #' || i.number || ')'
                  when i.kind = 'deposit' then 'Less deposit (invoice #' || i.number || ')' else 'Less progress billing (invoice #' || i.number || ')' end,
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
      -- A payment of the job's schedule is taken off by its name.
      cross join lateral (select private.installment_of_invoice(i.id) as payment) n
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
-- Which payment an invoice bills
-- ---------------------------------------------------------------------------------------------

-- As in 20261113001100_payment_schedules.sql (a deposit invoice made the usual way is the payment
-- due at approval), and now: an invoice made for a payment is that payment's as it's made, and a
-- final invoice, which bills everything left, is the invoice of every payment that has none.
create or replace function private.invoice_bills_installment() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_inst uuid := nullif(coalesce(current_setting('jobly.installment', true), ''), '')::uuid;
begin
  if tg_op = 'INSERT' and v_inst is not null then
    update public.job_installments s set invoice_id = new.id where s.id = v_inst and s.job_id = new.job_id;
  elsif new.kind = 'deposit' then
    update public.job_installments s set invoice_id = new.id
     where s.job_id = new.job_id and s.due = 'approval' and s.invoice_id is distinct from new.id
       and (s.invoice_id is null or exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status = 'void'));
  end if;
  if new.kind = 'standard' and new.billing_month is null and (tg_op = 'INSERT' or old.job_id is distinct from new.job_id) then
    update public.job_installments s set invoice_id = new.id
     where s.job_id = new.job_id and s.invoice_id is distinct from new.id
       and (s.invoice_id is null or exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status = 'void'));
  end if;
  return null;
end $$;
drop trigger bills_installment on public.invoices;
create trigger bills_installment after insert or update of job_id, status on public.invoices
  for each row when (new.job_id is not null and new.kind in ('deposit', 'progress', 'standard') and new.status <> 'void')
  execute function private.invoice_bills_installment();

-- As in 20261113001100_payment_schedules.sql, and a final invoice the job already has is the
-- invoice of every payment but the one a deposit invoice bills.
create or replace function private.schedule_to_job(p_quote uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  q public.quotes;
  j public.jobs;
  v_rows jsonb;
begin
  select * into q from public.quotes where id = p_quote;
  if not found or q.status not in ('approved', 'converted') then
    return;
  end if;
  v_rows := q.approval -> 'payment_schedule';
  if jsonb_typeof(v_rows) is distinct from 'array' or jsonb_array_length(v_rows) = 0 then
    return;
  end if;
  select * into j from public.jobs where company_id = q.company_id and quote_id = q.id order by created_at, id limit 1;
  if not found or j.kind = 'recurring' or exists (select 1 from public.job_installments where quote_id = q.id) then
    return;
  end if;
  insert into public.job_installments (company_id, job_id, quote_id, position, count, due, due_on, amount, percent, invoice_id)
  select q.company_id, j.id, q.id, e.i, jsonb_array_length(v_rows), e.row ->> 'due',
         case when e.row ->> 'due' = 'date' then (e.row ->> 'on')::date end,
         (e.row ->> 'amount')::numeric,
         case when e.row ->> 'kind' = 'percent' then round((e.row ->> 'value')::numeric, 2) end,
         coalesce(
           case when e.row ->> 'due' = 'approval' then coalesce(
             (select i.id from public.invoices i where i.id = q.deposit_invoice_id and i.status <> 'void'),
             (select i.id from public.invoices i where i.job_id = j.id and i.kind = 'deposit' and i.status <> 'void' order by i.created_at limit 1)) end,
           (select i.id from public.invoices i where i.job_id = j.id and i.kind = 'standard' and i.status <> 'void' order by i.created_at limit 1))
  from jsonb_array_elements(v_rows) with ordinality e (row, i);
end $$;

/**
 * Makes a payment's invoice through create_invoice_for_job (as the function's owner), as a draft:
 * the job's final invoice when it's the last payment without one, an invoice on account for its
 * amount otherwise (see the top of this file). p_by_hand: the office pressed Invoice now, so it's
 * made even when an earlier one was voided or deleted, and a reason it can't be is raised for them.
 * Otherwise (the moment came) it's made only the once: a problem is kept on the row and the office
 * is told, and a made one is either left for the server to send (the company's switch) or the office
 * is told it's ready. Returns the invoice, or null when nothing was made.
 */
create or replace function private.make_installment(p_installment uuid, p_by_hand boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  s public.job_installments;
  j public.jobs;
  v_invoice uuid;
  v_existing bigint;
  v_name text;
  v_total numeric;
  v_number bigint;
  v_kind text;
begin
  select * into s from public.job_installments where id = p_installment for update;
  if not found then
    raise exception 'Payment not found' using errcode = 'P0002';
  end if;
  select * into j from public.jobs where id = s.job_id;
  v_name := private.installment_name(s.position, s.count);
  select i.number into v_existing from public.invoices i where i.id = s.invoice_id and i.status <> 'void';
  if found then
    if p_by_hand then
      raise exception '% is on invoice #% already', v_name, v_existing using errcode = '22023';
    end if;
    return null;
  end if;
  if not p_by_hand and s.made_at is not null then
    return null;
  end if;
  -- A final invoice bills everything left as it's made, so nothing follows it. (A payment without an
  -- invoice here had one of its own that was voided after: the final invoice took that one off.)
  select i.number into v_existing from public.invoices i where i.job_id = j.id and i.kind = 'standard' and i.status <> 'void' order by i.number limit 1;
  if found then
    if p_by_hand then
      raise exception 'This job has its final invoice (#%), which bills what''s left. Void it first to invoice % by itself', v_existing, lower(left(v_name, 1)) || substr(v_name, 2)
        using errcode = '22023';
    end if;
    update public.job_installments set made_at = now() where id = s.id;
    return null;
  end if;

  -- The last payment without an invoice is the job's final invoice, which takes off the others and
  -- carries the tax, so it comes to what's left of the quote's total: its own amount. Any other is
  -- an invoice on account for exactly its amount: a deposit for the one due at approval, as always.
  v_kind := case when not exists (select 1 from private.unbilled_installments(j.id) x where x.id <> s.id) then 'standard'
                 when s.due = 'approval' then 'deposit' else 'progress' end;
  begin
    if v_kind <> 'standard' and s.amount <= 0 then
      raise exception 'It comes to $0.00, so there''s nothing to invoice' using errcode = '22023';
    end if;
    perform set_config('jobly.installment', s.id::text, true);
    v_invoice := public.create_invoice_for_job(j.id, v_kind, case when v_kind <> 'standard' then s.amount end);
    perform set_config('jobly.installment', '', true);
  exception when sqlstate '22023' or sqlstate 'P0002' then
    if p_by_hand then
      raise;
    end if;
    update public.job_installments set made_at = now(), problem = left(sqlerrm, 500) where id = s.id;
    perform private.job_notify(j.company_id, j.id, format('%s for job #%s couldn''t be invoiced', v_name, j.number),
      left(sqlerrm, 300) || '. Invoice it from the job when it''s sorted out.');
    return null;
  end;
  update public.invoices set subject = left(v_name || ': ' || j.title, 200) where id = v_invoice
  returning total, number into v_total, v_number;
  update public.job_installments
     set invoice_id = v_invoice, made_at = coalesce(made_at, now()), problem = null, send_error = null, send_claimed_at = null,
         send_state = case when not p_by_hand and private.sends_installments(j.company_id) then 'waiting' end
   where id = s.id;
  if not p_by_hand and not private.sends_installments(j.company_id) then
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    select j.company_id, u, 'invoice', left(format('%s for job #%s is ready to send', v_name, j.number), 300),
           format('Invoice #%s for %s to %s is in Drafts.', v_number, private.money(v_total), private.client_name(j.client_id)),
           '/invoices/' || v_invoice
    from private.money_office(j.company_id) u;
  end if;
  return v_invoice;
end $$;

-- ---------------------------------------------------------------------------------------------
-- A finished job with nothing left to bill
-- ---------------------------------------------------------------------------------------------

/**
 * Whether a job's schedule has billed all of it without a final invoice: every payment has an
 * invoice and they come to what the job comes to, tax included. Only jobs whose payments were all
 * made before this migration are like that (the last payment is the final invoice now); asking one
 * for its invoice would ask for a $0 one.
 */
create function private.schedule_billed_all(p_job uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.job_installments s where s.job_id = j.id)
     and not exists (select 1 from private.unbilled_installments(j.id))
     and coalesce((select sum(i.total) from public.invoices i where i.job_id = j.id and i.kind in ('deposit', 'progress') and i.status <> 'void'), 0)
         >= coalesce((select sum(round(l.quantity * l.unit_price, 2)) from public.job_line_items l where l.job_id = j.id), 0)
            + round(greatest(coalesce((select sum(round(l.quantity * l.unit_price, 2)) from public.job_line_items l where l.job_id = j.id and l.taxable), 0), 0)
                    * coalesce((select q.tax_rate from public.quotes q where q.id = j.quote_id), (c.settings ->> 'default_tax_rate')::numeric, 0), 2)
            - 0.005
  from public.jobs j join public.companies c on c.id = j.company_id
  where j.id = p_job
$$;
revoke all on function private.schedule_billed_all(uuid) from public;

-- As in 20261113000101_finished_jobs_ask_for_their_invoice.sql, and a job its payment schedule has
-- billed in full has nothing left to invoice.
create or replace function private.job_visits_finished(p_job uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  j public.jobs;
  v_name text;
  v_card uuid;
  v_to_invoice boolean;
begin
  -- Most visits finished are a recurring job's: those are left without a lock on the job.
  if not exists (select 1 from public.jobs x where x.id = p_job and x.kind = 'one_off' and x.status = 'active') then
    return;
  end if;
  -- Two crews finishing a job's last two visits at the same moment each see the other's still open.
  -- The job is locked first, so the second waits here and then sees the first's.
  select * into j from public.jobs where id = p_job for no key update;
  if not found or j.kind <> 'one_off' or j.status <> 'active' then
    return;
  end if;
  if exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status not in ('completed', 'cancelled'))
     or not exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status = 'completed') then
    return;
  end if;

  v_name := format('Job #%s for %s', j.number, private.client_name(j.client_id));
  -- What's left to invoice: a per-visit job's finished visits not on an invoice, any other job's
  -- final invoice (create_invoice_for_job makes one, and refuses a second), unless its payment
  -- schedule billed all of it before the last payment was the final invoice.
  v_to_invoice := case when j.billing_mode = 'per_visit'
    then exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status = 'completed' and v.invoice_id is null)
    else not exists (select 1 from public.invoices i where i.job_id = j.id and i.kind = 'standard' and i.status <> 'void')
         and not coalesce(private.schedule_billed_all(j.id), false) end;
  -- The card marking the work complete would charge: the same test as private.autopay_queue's.
  v_card := case when j.autopay and j.billing_mode = 'on_completion' then private.autopay_ready(j.company_id, j.client_id) end;

  if not v_to_invoice then
    if private.completes_finished_jobs(j.company_id) then
      perform set_config('jobly.job_finished', 'on', true);
      update public.jobs set status = 'completed', finished_by_visits_at = now() where id = j.id;
      perform set_config('jobly.job_finished', 'off', true);
    end if;
  elsif v_card is not null then
    perform private.job_notify(j.company_id, j.id, v_name || ' is finished. Mark work complete to charge their card',
      format('It''s on autopay, so it wasn''t marked complete for you. Pressing Mark work complete on the job charges %s.',
             coalesce(private.method_label_of(v_card), 'their saved card')));
  elsif not private.completes_finished_jobs(j.company_id) then
    perform private.job_notify(j.company_id, j.id, v_name || ' has had its last visit finished',
      'Press Mark work complete on the job when it''s ready to invoice.');
  else
    perform set_config('jobly.job_finished', 'on', true);
    update public.jobs set status = 'requires_invoicing', finished_by_visits_at = now() where id = j.id;
    perform set_config('jobly.job_finished', 'off', true);
    perform private.job_notify(j.company_id, j.id, v_name || ' is finished and ready to invoice',
      'Its last visit was finished, so the work was marked complete.');
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Jobs already on a schedule
-- ---------------------------------------------------------------------------------------------

-- A payment the hourly run found after the job's final invoice was marked "The final invoice (#N)
-- bills it". It's a payment on that invoice now, like the others that invoice billed, or, where that
-- invoice has since been voided, one to invoice by hand, with nothing written on it.
update public.job_installments s
   set problem = null,
       invoice_id = coalesce((select i.id from public.invoices i where i.job_id = s.job_id and i.kind = 'standard' and i.status <> 'void' and i.billing_month is null
                               order by i.number limit 1), s.invoice_id)
 where s.problem like 'The final invoice (#%) bills it'
   and not exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status <> 'void');
-- And the payments a final invoice billed without the hourly run ever looking at them.
update public.job_installments s
   set invoice_id = f.id
  from (select distinct on (i.job_id) i.job_id, i.id from public.invoices i
         where i.kind = 'standard' and i.status <> 'void' and i.billing_month is null and i.job_id is not null
         order by i.job_id, i.number) f
 where f.job_id = s.job_id and s.invoice_id is null;

notify pgrst, 'reload schema';
