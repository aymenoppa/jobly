-- A late fee can be taken off an invoice, and an invoice can be kept from ever getting one. Until
-- now the hourly run added the fee line (add_late_fees) and nothing could remove it short of moving
-- the invoice back to draft, which an invoice with a payment can't do.
--
--   invoices.no_late_fee   Late fees are off for this invoice: add_late_fees passes it by. The
--                          office ticks "No late fee on this invoice" (a plain update, under the
--                          invoices rules), before or after it's past due.
--   remove_late_fee()      Takes the fee line off a sent invoice, partly paid or not, and sets
--                          no_late_fee, so the next hourly run doesn't put it back. The totals,
--                          Stripe's copy and the books follow as they do for any change in what's
--                          owed. Noted in the activity log with who did it.
--
-- Not on a void or written-off invoice, nor while the client is being charged or a bank payment is
-- on its way for the amount with the fee, nor when the fee has been paid already (the total can't
-- go below what's been paid: refund the difference first).
-- supabase/tests/late_fee_off_test.sql covers it.

alter table public.invoices add column no_late_fee boolean not null default false;
comment on column public.invoices.no_late_fee is 'Late fees are off for this invoice: the hourly run (add_late_fees) never adds one. Set by the office, and by remove_late_fee.';

-- As in 20261107000100_deposit_invoice_terms.sql, except never on an invoice with late fees off.
create or replace function public.add_late_fees() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_fee numeric;
  v_count integer := 0;
  v_was text := coalesce(current_setting('jobly.late_fee', true), '');
begin
  for r in
    select i.id, i.company_id, i.balance_due, i.due_on, c.settings -> 'late_fee' as fee
      from public.invoices i
      join public.companies c on c.id = i.company_id
     where jsonb_typeof(c.settings -> 'late_fee') = 'object'
       and c.settings -> 'late_fee' ->> 'type' in ('flat', 'percent')
       and jsonb_typeof(c.settings -> 'late_fee' -> 'amount') = 'number'
       and coalesce(jsonb_typeof(c.settings -> 'late_fee' -> 'grace_days'), 'number') = 'number'
       and i.status in ('sent', 'partially_paid', 'overdue')
       and i.kind <> 'deposit'
       and not i.no_late_fee
       and i.balance_due > 0
       and i.late_fee_at is null
       and i.due_on + coalesce((c.settings -> 'late_fee' ->> 'grace_days')::numeric::integer, 0) < (now() at time zone c.timezone)::date
       and not exists (select 1 from public.stripe_invoices s where s.invoice_id = i.id and (s.origin = 'stripe' or s.status = 'processing'))
       and not exists (select 1 from public.autopay_charges a where a.invoice_id = i.id and a.status in ('charging', 'processing'))
     for update of i skip locked
  loop
    v_fee := case r.fee ->> 'type'
      when 'flat' then round((r.fee ->> 'amount')::numeric, 2)
      else round(r.balance_due * (r.fee ->> 'amount')::numeric / 100, 2) end;
    update public.invoices set late_fee_at = now() where id = r.id and late_fee_at is null;
    if found and v_fee > 0 then
      perform set_config('jobly.late_fee', 'on', true);
      insert into public.invoice_line_items (company_id, invoice_id, name, description, quantity, unit, unit_price, taxable, sort, kind)
      values (r.company_id, r.id, 'Late fee', 'The invoice was due ' || to_char(r.due_on, 'FMMonth FMDD, YYYY'), 1, 'ea', v_fee, false,
              coalesce((select max(sort) from public.invoice_line_items where invoice_id = r.id), 0) + 1, 'late_fee');
      perform set_config('jobly.late_fee', v_was, true);
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;

/**
 * Remove late fee: the invoice's late fee line comes off and late fees are turned off for it. For
 * owners, admins and the office with the invoices area. Returns what came off (0 when it had no fee
 * line: late fees are just turned off for it).
 */
create function public.remove_late_fee(p_invoice uuid) returns numeric
language plpgsql security definer set search_path = '' as $$
declare
  i public.invoices;
  v_fee numeric;
  v_was text := coalesce(current_setting('jobly.late_fee', true), '');
begin
  select * into i from public.invoices where id = p_invoice for update;
  if not found or not (private.has_role(i.company_id, '{owner,admin,office}') and private.has_perm(i.company_id, 'invoices')) then
    raise exception 'Invoice not found' using errcode = 'P0002';
  end if;
  if i.status = 'void' then
    raise exception 'A void invoice stays as it is' using errcode = '22023';
  elsif i.status = 'written_off' then
    raise exception 'Undo the write-off before changing this invoice' using errcode = '22023';
  end if;
  select coalesce(sum(round(quantity * unit_price, 2)), 0) into v_fee
  from public.invoice_line_items where invoice_id = i.id and kind = 'late_fee';
  if v_fee <> 0 then
    -- The client is paying the amount with the fee in it right now.
    if exists (select 1 from public.autopay_charges a where a.invoice_id = i.id and a.status = 'charging' and a.claim_token is not null) then
      raise exception 'This invoice is being charged automatically right now. Try again in a few minutes' using errcode = '22023';
    end if;
    if private.bank_payment_clearing(i.id) or private.autopay_clearing(i.id) then
      raise exception 'A bank payment for this invoice is on its way. Remove the late fee once it clears or bounces' using errcode = '22023';
    end if;
    perform set_config('jobly.late_fee', 'on', true);
    delete from public.invoice_line_items where invoice_id = i.id and kind = 'late_fee';
    perform set_config('jobly.late_fee', v_was, true);
  end if;
  -- Its totals are worked out again with this (the line's own touch did too).
  update public.invoices set no_late_fee = true where id = i.id returning * into i;
  if v_fee <> 0 then
    if i.balance_due < 0 then
      raise exception 'This invoice has % paid on it, so its total can''t go below that. Refund the difference first.', private.money(i.amount_paid)
        using errcode = '22023';
    end if;
    perform private.emit(i.company_id, 'invoice.late_fee_removed', 'invoice', i.id,
      format('%s late fee taken off invoice #%s for %s', private.money(v_fee), i.number, private.client_name(i.client_id)),
      jsonb_build_object('number', i.number, 'late_fee', v_fee, 'total', i.total, 'balance_due', i.balance_due));
  end if;
  return v_fee;
end $$;
revoke execute on function public.remove_late_fee(uuid) from public, anon;
grant execute on function public.remove_late_fee(uuid) to authenticated;

-- An assistant with the invoices area may call it (as in 20261112000530_assistants_off_everywhere.sql,
-- with remove_late_fee added).
create or replace function private.assistant_rpc_area(p_function text) returns text
language sql immutable set search_path = '' as $$
  select case p_function
    when 'convert_quote_to_job' then 'quotes'
    when 'create_invoice_for_job' then 'invoices'
    when 'duplicate_quote' then 'quotes'
    when 'merge_clients' then 'invoices'
    when 'merge_company_settings' then 'company'
    when 'quote_exact_sent' then 'quotes'
    when 'remove_late_fee' then 'invoices'
    when 'set_checklist_services' then 'checklists'
    when 'set_weather_rules' then 'prices'
  end
$$;

notify pgrst, 'reload schema';
