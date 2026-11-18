-- An invoice that has been sent can be edited, payments and all. Its lines changed only while it
-- was a draft, and an invoice with a payment row couldn't go back to draft, so after a part payment
-- the office couldn't add extra work or fix a line, and one paid through Stripe couldn't be
-- corrected at all.
--
-- edit_invoice(invoice, lines) changes a sent invoice's lines in place, in one step: the invoice
-- never leaves the client's link or the reports, its payments (their dates and Stripe links) aren't
-- touched, and nothing sees it half changed. Its totals and status are worked out once, from the
-- new lines, by the trigger that always works them out (private.invoice_totals), so what follows a
-- change in what's owed follows as it does today: Stripe's copy is replaced, the books get the
-- update, and a paid invoice that owes again past its due date waits a day before any reminder
-- (20261113000430_owed_again_without_chasing.sql). The rules:
--
--   The total     can't go below what has been paid on it, net of refunds. Refund the difference first.
--   Locked lines  stay as they are: a late fee (Remove late fee takes it off), the Minimum charge
--                 line, a promo code's discount, and a final invoice's credits for the job's
--                 deposit and progress invoices. The lines given replace all the others.
--   Not at all    a void or written-off invoice, one made in Stripe, one being charged or with a
--                 bank payment on its way.
--   A job's       deposit and progress invoices: not once the job's final invoice has taken them
--   billing       off, and never past what's left to bill on the job. Retainage: never more than
--                 the job's other invoices hold back, whichever of them is edited.
--   The log       invoice.edited in the activity log, with who and the old and new total.
--
-- With p_preview it changes nothing and says what the invoice would come to, or why it can't be
-- done: the edit screen asks as the office types, so the figures it shows are the database's.
-- A draft's lines can be given the same way (an assistant does), under the draft's own rules.
-- supabase/tests/edit_invoice_test.sql covers it.

-- A line an edit leaves as it is.
create function private.invoice_line_locked(l public.invoice_line_items) returns boolean
language sql immutable set search_path = '' as $$
  select l.kind is not null or l.discount_quote_id is not null
      or (l.unit_price < 0 and l.name ~ '^Less (deposit|progress billing) \(invoice #[0-9]+\)$')
$$;

-- As in 20261104000200_client_billing_late_fees.sql, except that edit_invoice changes a sent
-- invoice's lines, and the refusal names it.
create or replace function private.invoice_lines_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(current_setting('jobly.late_fee', true), '') = 'on' or coalesce(current_setting('jobly.invoice_edit', true), '') = 'on' then
    return coalesce(new, old);
  end if;
  if tg_op = 'UPDATE' and old.service_id is not null and new.service_id is null
     and to_jsonb(new) - 'service_id' = to_jsonb(old) - 'service_id' then
    return new;
  end if;
  if exists (
    select 1 from public.invoices i
    where i.id in (case when tg_op <> 'DELETE' then new.invoice_id end, case when tg_op <> 'INSERT' then old.invoice_id end)
      and i.status <> 'draft'
  ) then
    raise exception 'This invoice has been sent. Use Edit invoice to change its line items' using errcode = '22023';
  end if;
  return coalesce(new, old);
end $$;

-- The books' copy of a sent invoice is queued for an update, on the terms private.enqueue_accounting
-- queues one (20261112000470_accounting_links_per_books.sql): that trigger goes by the invoice's
-- figures, and an edit can change its lines without moving any of them.
create function private.queue_invoice_for_books(p_invoice uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  i public.invoices;
  v_provider text;
  v_account text;
  v_books jsonb := '{}';
begin
  if coalesce(current_setting('jobly.quiet', true), '') = 'on' then
    return;
  end if;
  select * into i from public.invoices where id = p_invoice;
  if not found or i.status in ('draft', 'void') then
    return;
  end if;
  select g.provider, g.external_account_id into v_provider, v_account
  from public.integrations g
  where g.company_id = i.company_id and g.provider in ('quickbooks', 'zoho_books') and g.status in ('connected', 'error')
  order by (g.status = 'connected') desc, g.provider
  limit 1;
  if not found then
    return;
  end if;
  if v_account is not null then
    v_books := jsonb_build_object('provider', v_provider, 'account_id', v_account);
  end if;
  if (exists (select 1 from public.sync_links l where l.company_id = i.company_id and l.entity = 'invoice' and l.local_id = i.id)
      or exists (select 1 from public.outbox o where o.topic = 'accounting.invoice' and o.payload ->> 'invoice_id' = i.id::text and o.company_id = i.company_id))
     and not exists (
       select 1 from public.outbox o
       where o.topic = 'accounting.invoice' and o.payload ->> 'invoice_id' = i.id::text and o.company_id = i.company_id
         and o.done_at is null and o.dead_at is null and (o.locked_until is null or o.locked_until < now())
         and (o.payload ->> 'account_id' is null or v_account is null
              or (o.payload ->> 'provider', o.payload ->> 'account_id') = (v_provider, v_account))) then
    insert into public.outbox (company_id, topic, payload)
    values (i.company_id, 'accounting.invoice', jsonb_build_object('invoice_id', i.id) || v_books);
  end if;
end $$;

/**
 * Edit invoice. p_lines is the invoice's ordinary lines as they should be, in order: each
 * {id (an existing line's, left out for a new one), name, description, quantity, unit, unit_price,
 * taxable, service_id (new lines)}. Ordinary lines not listed are removed; locked lines
 * (private.invoice_line_locked) stay and follow them. For owners, admins and the office with the
 * invoices area. Returns the invoice's figures after the change (with p_preview: as they would be).
 * p_updated_at, when given, is the invoice's updated_at as the editor read it: if the invoice has
 * changed since (a payment came in, someone else edited it), nothing is changed and it says so.
 */
create function public.edit_invoice(p_invoice uuid, p_lines jsonb, p_preview boolean default false, p_updated_at timestamptz default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  i public.invoices;
  n public.invoices;
  v_job uuid;
  v_job_kind text;
  v_contract numeric;
  v_number bigint;
  v_count integer;
  v_gone integer;
  v_made integer;
  v_changed integer;
  v_pre_before numeric := 0; v_held_before numeric := 0; v_kept_before numeric := 0;
  v_pre numeric := 0; v_held numeric := 0; v_kept numeric := 0;
  v_credits numeric;
  v_quote_total numeric;
  v_result jsonb;
  v_was text := coalesce(current_setting('jobly.invoice_edit', true), '');
begin
  -- One change to a job's invoices at a time, as when one is made (create_invoice_for_job).
  select job_id into v_job from public.invoices where id = p_invoice;
  if v_job is not null then
    perform pg_advisory_xact_lock(hashtextextended('invoice-for-job:' || v_job::text, 0));
  end if;
  select * into i from public.invoices where id = p_invoice for update;
  if not found or not (private.has_role(i.company_id, '{owner,admin,office}') and private.has_perm(i.company_id, 'invoices')) then
    raise exception 'Invoice not found' using errcode = 'P0002';
  end if;

  if p_updated_at is not null and i.updated_at is distinct from p_updated_at then
    raise exception 'This invoice changed while you were editing it. Close this, look at it again and make your changes once more' using errcode = '22023';
  end if;
  if i.status = 'void' then
    raise exception 'A void invoice stays as it is' using errcode = '22023';
  elsif i.status = 'written_off' then
    raise exception 'Undo the write-off before changing this invoice' using errcode = '22023';
  end if;
  if private.stripe_collects(i.id) then
    raise exception 'This invoice was made in Stripe. Make changes there' using errcode = '22023';
  end if;
  if exists (select 1 from public.autopay_charges a where a.invoice_id = i.id and a.status = 'charging' and a.claim_token is not null) then
    raise exception 'This invoice is being charged automatically right now. Try again in a few minutes' using errcode = '22023';
  end if;
  if private.bank_payment_clearing(i.id) or private.autopay_clearing(i.id) then
    raise exception 'A bank payment for this invoice is on its way. Change it once it clears or bounces' using errcode = '22023';
  end if;
  -- The job's final invoice took this one off as it stood.
  if i.status <> 'draft' and i.kind in ('deposit', 'progress') and i.job_id is not null then
    select x.number into v_number from public.invoices x
    where x.job_id = i.job_id and x.kind = 'standard' and x.status <> 'void' and x.billing_month is null and x.id <> i.id and x.created_at >= i.created_at
    order by x.number limit 1;
    if found then
      raise exception 'Invoice #% already takes this one off the job''s total. Void that invoice to change this one', v_number using errcode = '22023';
    end if;
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Give the invoice''s lines' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_lines);
  if v_count > 200 then
    raise exception 'An invoice takes up to 200 lines' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l where jsonb_typeof(l) <> 'object' or btrim(coalesce(l ->> 'name', '')) = '') then
    raise exception 'Every line needs a name' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lines) l
             where length(l ->> 'name') > 300 or length(l ->> 'description') > 2000 or length(l ->> 'unit') > 30
                or abs(coalesce((l ->> 'quantity')::numeric, 1)) >= 100000000 or abs(coalesce((l ->> 'unit_price')::numeric, 0)) >= 100000000) then
    raise exception 'One of the lines is too long or too large' using errcode = '22023';
  end if;
  -- Every line named is one of this invoice's that can change, once.
  if exists (select 1 from jsonb_array_elements(p_lines) l where l ->> 'id' is not null
             and not exists (select 1 from public.invoice_line_items x where x.id = (l ->> 'id')::uuid and x.invoice_id = i.id and not private.invoice_line_locked(x)))
     or (select count(*) <> count(distinct l ->> 'id') from jsonb_array_elements(p_lines) l where l ->> 'id' is not null) then
    raise exception 'One of those lines isn''t on this invoice, or can''t be changed here. Open the invoice again and try once more' using errcode = '22023';
  end if;
  if v_count = 0 and not exists (select 1 from public.invoice_line_items x where x.invoice_id = i.id and private.invoice_line_locked(x)) then
    raise exception 'An invoice needs at least one line' using errcode = '22023';
  end if;

  if i.job_id is not null then
    select j.kind, f.contract_total into v_job_kind, v_contract
    from public.jobs j left join public.job_financials f on f.job_id = j.id where j.id = i.job_id;
    select coalesce(sum(x.subtotal) filter (where x.kind in ('deposit', 'progress')), 0),
           coalesce(sum(x.retainage_amount) filter (where x.kind <> 'retainage'), 0),
           coalesce(sum(x.subtotal) filter (where x.kind = 'retainage'), 0)
      into v_pre_before, v_held_before, v_kept_before
    from public.invoices x where x.job_id = i.job_id and x.status <> 'void';
  end if;

  -- Everything from here is undone again for a preview.
  begin
    -- How many of the lines kept change in what they say (their place aside).
    select count(*) into v_changed
    from jsonb_array_elements(p_lines) l
    join public.invoice_line_items x on x.id = (l ->> 'id')::uuid
    where (x.name, coalesce(x.description, ''), x.quantity, x.unit, x.unit_price, x.taxable)
          is distinct from (btrim(l ->> 'name'), btrim(coalesce(l ->> 'description', '')), coalesce((l ->> 'quantity')::numeric, 1)::numeric(14, 3),
                            coalesce(nullif(btrim(coalesce(l ->> 'unit', '')), ''), 'ea'), coalesce((l ->> 'unit_price')::numeric, 0)::numeric(12, 2),
                            coalesce((l ->> 'taxable')::boolean, true));

    -- One statement, so the invoice's totals and status are worked out from the lines as they end
    -- up, never from a state in between (the lines' triggers run once it's done).
    perform set_config('jobly.invoice_edit', 'on', true);
    with want as (
      select (x.ord - 1)::integer as sort, (x.l ->> 'id')::uuid as id, btrim(x.l ->> 'name') as name,
             nullif(btrim(coalesce(x.l ->> 'description', '')), '') as description,
             coalesce((x.l ->> 'quantity')::numeric, 1) as quantity,
             coalesce(nullif(btrim(coalesce(x.l ->> 'unit', '')), ''), 'ea') as unit,
             coalesce((x.l ->> 'unit_price')::numeric, 0) as unit_price,
             coalesce((x.l ->> 'taxable')::boolean, true) as taxable,
             (x.l ->> 'service_id')::uuid as service_id
      from jsonb_array_elements(p_lines) with ordinality x(l, ord)
    ),
    gone as (
      delete from public.invoice_line_items l
      where l.invoice_id = i.id and not private.invoice_line_locked(l) and not exists (select 1 from want w where w.id = l.id)
      returning l.id
    ),
    kept as (
      update public.invoice_line_items l
      set name = w.name, description = w.description, quantity = w.quantity, unit = w.unit, unit_price = w.unit_price, taxable = w.taxable, sort = w.sort
      from want w
      where l.id = w.id and l.invoice_id = i.id
        and (l.name, l.description, l.quantity, l.unit, l.unit_price, l.taxable, l.sort)
            is distinct from (w.name, w.description, w.quantity::numeric(14, 3), w.unit, w.unit_price::numeric(12, 2), w.taxable, w.sort)
      returning l.id
    ),
    made as (
      insert into public.invoice_line_items (company_id, invoice_id, service_id, name, description, quantity, unit, unit_price, taxable, sort)
      select i.company_id, i.id, w.service_id, w.name, w.description, w.quantity, w.unit, w.unit_price, w.taxable, w.sort
      from want w where w.id is null
      returning id
    ),
    -- The locked lines follow the others, in the order they were in.
    last as (
      update public.invoice_line_items l set sort = v_count + r.place
      from (select x.id, (row_number() over (order by x.sort, x.id) - 1)::integer as place
            from public.invoice_line_items x where x.invoice_id = i.id and private.invoice_line_locked(x)) r
      where l.id = r.id and l.sort is distinct from v_count + r.place
      returning l.id
    )
    select (select count(*) from gone), (select count(*) from made) into v_gone, v_made;
    perform set_config('jobly.invoice_edit', v_was, true);
    v_changed := v_changed + v_gone + v_made;

    select * into n from public.invoices where id = i.id;

    if n.status <> 'draft' then
      if n.amount_paid > 0 and n.balance_due < 0 and n.balance_due < i.balance_due then
        raise exception 'This invoice has % paid on it, so its total can''t go below that. Refund the difference first.', private.money(n.amount_paid)
          using errcode = '22023';
      end if;
      select coalesce(sum(amount), 0) into v_credits from public.referral_credits where invoice_id = i.id;
      if v_credits > n.credit_amount and n.credit_amount < i.credit_amount then
        raise exception 'This invoice has a % referral credit on it, so its lines can''t come to less than that', private.money(v_credits) using errcode = '22023';
      end if;
      if i.job_id is not null then
        select coalesce(sum(x.subtotal) filter (where x.kind in ('deposit', 'progress')), 0),
               coalesce(sum(x.retainage_amount) filter (where x.kind <> 'retainage'), 0),
               coalesce(sum(x.subtotal) filter (where x.kind = 'retainage'), 0)
          into v_pre, v_held, v_kept
        from public.invoices x where x.job_id = i.job_id and x.status <> 'void';
        -- As create_invoice_for_job holds a new deposit or progress invoice to what's left on the job.
        if i.kind in ('deposit', 'progress') and v_job_kind <> 'recurring' and v_pre > coalesce(v_contract, 0) + 0.005 and v_pre > v_pre_before then
          raise exception 'That''s more than what''s left to bill on this job (%)',
            to_char(greatest(coalesce(v_contract, 0) - (v_pre - n.subtotal), 0), 'FM$999,999,990.00') using errcode = '22023';
        end if;
        if v_kept > v_held + 0.005 and v_kept - v_held > v_kept_before - v_held_before then
          if i.kind = 'retainage' then
            raise exception 'That''s more than the retainage held back on this job (%)',
              to_char(greatest(v_held - (v_kept - n.subtotal), 0), 'FM$999,999,990.00') using errcode = '22023';
          end if;
          raise exception 'This job''s retainage invoice bills what this one holds back, so its total can''t go that low. Change the retainage invoice first'
            using errcode = '22023';
        end if;
      elsif i.kind = 'deposit' then
        -- Made as the client approved, before there's a job: never more than the quote comes to.
        select q.total into v_quote_total from public.quotes q where q.deposit_invoice_id = i.id;
        if found and n.subtotal > v_quote_total + 0.005 and n.subtotal > i.subtotal then
          raise exception 'A deposit can''t be more than the quote comes to (%)', to_char(v_quote_total, 'FM$999,999,990.00') using errcode = '22023';
        end if;
      end if;
    end if;

    v_result := jsonb_build_object('id', n.id, 'status', n.status, 'subtotal', n.subtotal, 'discount_amount', n.discount_amount, 'credit_amount', n.credit_amount,
      'tax_amount', n.tax_amount, 'total', n.total, 'retainage_amount', n.retainage_amount, 'amount_paid', n.amount_paid, 'balance_due', n.balance_due,
      'changed', v_changed, 'old_total', i.total, 'old_status', i.status);

    if p_preview then
      raise exception using errcode = 'CTPRV', message = 'preview';
    end if;

    if v_changed > 0 and n.status <> 'draft' then
      perform private.emit(i.company_id, 'invoice.edited', 'invoice', i.id,
        case when n.total = i.total
          then format('Invoice #%s for %s edited (total still %s)', i.number, private.client_name(i.client_id), private.money(n.total))
          else format('Invoice #%s for %s edited: total %s, was %s', i.number, private.client_name(i.client_id), private.money(n.total), private.money(i.total)) end,
        jsonb_build_object('number', i.number, 'old_total', i.total, 'new_total', n.total, 'total', n.total, 'balance_due', n.balance_due,
          'lines_added', v_made, 'lines_removed', v_gone));
      perform private.queue_invoice_for_books(i.id);
    end if;
  exception when sqlstate 'CTPRV' then
    -- A preview: the lines are as they were, and v_result says what they'd have come to.
    null;
  end;
  return v_result;
end $$;
revoke execute on function public.edit_invoice(uuid, jsonb, boolean, timestamptz) from public, anon;
grant execute on function public.edit_invoice(uuid, jsonb, boolean, timestamptz) to authenticated;
revoke all on function private.invoice_line_locked(public.invoice_line_items), private.queue_invoice_for_books(uuid) from public;

-- An assistant with the invoices area may call it (as in 20261113000420_late_fee_off_for_an_invoice.sql,
-- with edit_invoice added).
create or replace function private.assistant_rpc_area(p_function text) returns text
language sql immutable set search_path = '' as $$
  select case p_function
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
  end
$$;

notify pgrst, 'reload schema';
