-- The job's Invoice button doesn't bill a dated payment before its day.
--
-- A schedule like 30% at approval, 60% when the work is done and 10% thirty days later leaves the
-- job, once its work is done and that payment invoiced, waiting only for the last payment's day.
-- The hourly run invoices it then. Until then the job still reads "Requires invoicing", and its
-- Invoice button (or a batch of finished jobs invoiced together) would make the final invoice at
-- once: the 10% the client signed for next month, billed today.
--
-- Now a final invoice asked for on a job whose only payments without an invoice are dated ones with
-- their day still to come is refused, saying which payment is waiting and for when. Billing it
-- sooner is still a choice: Invoice now, on the payment itself.
--
-- supabase/tests/payment_shapes_test.sql covers it.

/**
 * Why a job's final invoice should wait, in words for whoever pressed Invoice, or null: every
 * payment of its schedule that has no invoice is a dated one whose day (where the company is) is
 * still to come. Names the next of them.
 */
create function private.installments_wait_for_their_day(p_job uuid) returns text
language sql stable security definer set search_path = '' as $$
  select case when bool_and(s.due = 'date' and s.due_on > private.company_today(s.company_id))
              then (select format('%s (%s) is due on %s and is invoiced by itself that day. To bill it sooner, use Invoice now on the job''s payment schedule',
                                  private.installment_name(x.position, x.count), private.money(x.amount), to_char(x.due_on, 'Mon FMDD, YYYY'))
                      from private.unbilled_installments(p_job) x order by x.due_on, x.position limit 1) end
    from private.unbilled_installments(p_job) s
$$;
revoke all on function private.installments_wait_for_their_day(uuid) from public;
grant execute on function private.installments_wait_for_their_day(uuid) to authenticated, service_role;

-- As in 20261113001600_scheduled_payments_bill_what_was_signed.sql, and a final invoice waits while
-- all that's left of the schedule is dated payments whose day hasn't come.
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
  v_wait text;
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
  -- A final invoice bills everything left. When all that's left is payments that have a day still
  -- to come, each is invoiced by itself on its day, so the button doesn't bill them early by habit
  -- (or a batch of finished jobs by accident): Invoice now, on the payment, is how that's chosen.
  if v_inst is null and p_kind = 'standard' and p_month is null and j.kind <> 'recurring' then
    v_wait := private.installments_wait_for_their_day(j.id);
    if v_wait is not null then
      raise exception '%', v_wait using errcode = '22023';
    end if;
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

notify pgrst, 'reload schema';
