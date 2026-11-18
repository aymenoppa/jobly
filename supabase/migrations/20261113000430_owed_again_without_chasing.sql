-- A paid invoice that's owed again doesn't chase the client that day. Removing a mis-keyed payment
-- or recording a refund puts the balance back; when the due date had passed the invoice went
-- straight to overdue, which raised invoice.overdue (the "Remind clients when an invoice is past
-- due" rule emails them at once) and the next hourly run added a late fee counted from the old due
-- date. All for something the office just did itself. Now, when a paid invoice becomes overdue
-- (a payment removed, a refund or dispute, a referral credit taken back, an edit that adds to it):
--
--   invoices.owed_again_at             says when. The invoice reads past due to the office at once.
--   invoices.past_due_notice_pending   its invoice.overdue event hasn't been raised: the hourly run
--                                      raises it from the next day where the business is
--                                      (raise_past_due_notices), so reminders and the rules that
--                                      follow it carry on from then. Paid or written off first, it
--                                      never is.
--   Late fee                           the grace days count from the day it was owed again, when
--                                      that's after the due date (add_late_fees; core lateFeeOn).
--
-- An invoice that goes past its due date in the ordinary way is as before.
-- supabase/tests/owed_again_test.sql covers it.

alter table public.invoices
  add column owed_again_at timestamptz,
  add column past_due_notice_pending boolean not null default false;
comment on column public.invoices.owed_again_at is 'When it last went from paid to past due with a balance (a payment removed, a refund, an edit). A late fee''s grace days count from then. Set by the database.';
comment on column public.invoices.past_due_notice_pending is 'Owed again and past due, with its invoice.overdue event still to raise: the hourly run does, from the day after owed_again_at. Set by the database.';
-- The few the hourly run has to look at.
create index invoices_past_due_notice_idx on public.invoices (company_id) where past_due_notice_pending;

-- As in 20261107000200_merge_keeps_invoice_status.sql, plus owed_again_at and past_due_notice_pending.
create or replace function private.invoice_totals() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_sub numeric; v_taxable numeric; v_base numeric; v_base_taxable numeric; v_lines integer;
  v_discount numeric; v_credits numeric; v_off numeric; v_paid numeric; v_today date;
begin
  if tg_op = 'UPDATE' and old.status = 'void' and new.status = 'void' then
    new.subtotal := old.subtotal;
    new.discount_amount := old.discount_amount;
    new.credit_amount := old.credit_amount;
    new.tax_amount := old.tax_amount;
    new.total := old.total;
    new.retainage_amount := old.retainage_amount;
    new.amount_paid := coalesce((select sum(amount) from public.payments where invoice_id = new.id), 0);
    new.balance_due := new.total - new.retainage_amount - new.amount_paid;
    return new;
  end if;
  select coalesce(sum(round(quantity * unit_price, 2)), 0),
         coalesce(sum(round(quantity * unit_price, 2)) filter (where taxable), 0),
         coalesce(sum(round(quantity * unit_price, 2)) filter (where unit_price > 0), 0),
         coalesce(sum(round(quantity * unit_price, 2)) filter (where taxable and unit_price > 0), 0),
         count(*)
    into v_sub, v_taxable, v_base, v_base_taxable, v_lines
  from public.invoice_line_items where invoice_id = new.id;
  select coalesce(sum(amount), 0) into v_paid from public.payments where invoice_id = new.id;
  select (now() at time zone coalesce(c.timezone, 'UTC'))::date into v_today from public.companies c where c.id = new.company_id;

  if new.promo_code_id is not null then
    new.discount_amount := coalesce(private.promo_discount(new.promo_code_id, v_base), 0);
  end if;
  v_discount := least(new.discount_amount, greatest(v_sub, 0));
  select coalesce(sum(amount), 0) into v_credits from public.referral_credits where invoice_id = new.id;
  new.credit_amount := least(v_credits, greatest(v_sub - v_discount, 0));
  v_off := v_discount + new.credit_amount;
  new.subtotal := v_sub;
  new.tax_amount := round(greatest(v_taxable - case when v_base > 0 then v_off * v_base_taxable / v_base else 0 end, 0) * new.tax_rate, 2);
  new.total := v_sub - v_off + new.tax_amount;
  new.retainage_amount := round(greatest(new.total, 0) * new.retainage_pct / 100, 2);
  new.amount_paid := v_paid;
  new.balance_due := new.total - new.retainage_amount - v_paid;

  if tg_op = 'UPDATE' and private.merging_clients(null, new.client_id) then
    -- Moved by a merge (or its payments were): it keeps its status, which the hourly upkeep changes
    -- later as it would have without the merge, so a merge never marks one overdue (and emails).
    new.status := old.status;
  elsif new.status = 'written_off' and (tg_op = 'INSERT' or old.status <> 'written_off') then
    -- Being written off now: invoice_void_guard checks there's something owed to write off.
    if tg_op = 'INSERT' then
      raise exception 'Send an invoice before writing it off' using errcode = '22023';
    end if;
  elsif new.status = 'written_off' then
    -- Paid after all.
    if v_lines > 0 and new.balance_due <= 0 then
      new.status := 'paid';
    end if;
  elsif new.status not in ('draft', 'void') then
    new.status := case
      when v_lines > 0 and new.balance_due <= 0 then 'paid'
      when new.due_on is not null and new.due_on < coalesce(v_today, current_date) then 'overdue'
      when v_paid > 0 then 'partially_paid'
      else 'sent'
    end;
  end if;
  -- Owed again: paid, and now past due with a balance (a payment removed, a refund, a dispute, an
  -- edit that added to it). That isn't an invoice going past its due date, so its past-due event
  -- waits for the hourly run (raise_past_due_notices) and its late fee's grace days count from now.
  -- Only this sets the two columns; anyone may call the notice off.
  if tg_op = 'INSERT' then
    new.owed_again_at := null;
    new.past_due_notice_pending := false;
  else
    new.owed_again_at := old.owed_again_at;
    if old.status = 'paid' and new.status = 'overdue' then
      new.owed_again_at := now();
      new.past_due_notice_pending := true;
    elsif new.status <> 'overdue' or not old.past_due_notice_pending then
      new.past_due_notice_pending := false;
    end if;
  end if;
  new.written_off_at := case when new.status = 'written_off' then coalesce(new.written_off_at, now()) end;
  if new.status not in ('draft', 'void') and new.sent_at is null then
    new.sent_at := now();
  end if;
  return new;
end $$;

-- As in 20261101000100_autopay.sql, except a paid invoice owed again isn't "just became past due".
create or replace function private.activity_invoices() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_client text := private.client_name(new.client_id);
  v_data jsonb := jsonb_build_object('number', new.number, 'total', new.total, 'balance_due', new.balance_due,
    'autopay', exists (select 1 from public.autopay_charges a where a.invoice_id = new.id and a.status <> 'called_off'));
  v_credit boolean := coalesce(new.amount_paid, 0) = 0 and coalesce(new.credit_amount, 0) > 0;
begin
  if (tg_op = 'INSERT' and new.status <> 'draft') or (tg_op = 'UPDATE' and new.status is distinct from old.status) then
    case new.status
      when 'sent' then
        if tg_op = 'INSERT' or old.status = 'draft' then
          perform private.emit(new.company_id, 'invoice.sent', 'invoice', new.id, format('Invoice #%s sent to %s (%s)', new.number, v_client, private.money(new.total)), v_data);
        end if;
      when 'paid' then
        perform private.emit(new.company_id, 'invoice.paid', 'invoice', new.id,
          case
            when v_credit then format('Invoice #%s for %s covered by a referral credit', new.number, v_client)
            when coalesce(new.amount_paid, 0) = 0 then format('Invoice #%s for %s had nothing to pay', new.number, v_client)
            else format('Invoice #%s paid by %s (%s)', new.number, v_client, private.money(new.total)) end,
          v_data || jsonb_build_object('amount_paid', coalesce(new.amount_paid, 0), 'covered_by_credit', v_credit));
      when 'overdue' then
        -- Not for one owed again after being paid: the hourly run raises it the next day.
        if (tg_op = 'INSERT' or old.status <> 'written_off') and not new.past_due_notice_pending then
          perform private.emit(new.company_id, 'invoice.overdue', 'invoice', new.id, format('Invoice #%s for %s is past due (%s owing)', new.number, v_client, private.money(new.balance_due)), v_data);
        end if;
      when 'written_off' then
        perform private.emit(new.company_id, 'invoice.written_off', 'invoice', new.id, format('Invoice #%s for %s written off (%s)', new.number, v_client, private.money(new.balance_due)), v_data);
      else null;
    end case;
  end if;
  return null;
end $$;

/**
 * Hourly (tasks.ts): the past-due event of each invoice that was paid and is owed again, from the
 * day after it was, where the business is. Raised once, as the invoice going overdue would have
 * raised it. One paid, written off or voided since has nothing to raise. Returns how many.
 */
create function public.raise_past_due_notices() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select i.id, i.company_id, i.client_id, i.number, i.total, i.balance_due
      from public.invoices i
      join public.companies c on c.id = i.company_id
     where i.past_due_notice_pending and i.status = 'overdue' and i.balance_due > 0
       and (i.owed_again_at at time zone coalesce(c.timezone, 'UTC'))::date < (now() at time zone coalesce(c.timezone, 'UTC'))::date
     for update of i skip locked
  loop
    update public.invoices set past_due_notice_pending = false where id = r.id;
    perform private.emit(r.company_id, 'invoice.overdue', 'invoice', r.id,
      format('Invoice #%s for %s is past due (%s owing)', r.number, private.client_name(r.client_id), private.money(r.balance_due)),
      jsonb_build_object('number', r.number, 'total', r.total, 'balance_due', r.balance_due,
        'autopay', exists (select 1 from public.autopay_charges a where a.invoice_id = r.id and a.status <> 'called_off')));
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;
revoke execute on function public.raise_past_due_notices() from public, anon, authenticated;
grant execute on function public.raise_past_due_notices() to service_role;

-- As in 20261113000420_late_fee_off_for_an_invoice.sql, except the grace days of an invoice owed
-- again count from then.
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
       -- The grace days count from the due date, or from the day it was owed again if that's later.
       and greatest(i.due_on, coalesce((i.owed_again_at at time zone c.timezone)::date, i.due_on))
           + coalesce((c.settings -> 'late_fee' ->> 'grace_days')::numeric::integer, 0) < (now() at time zone c.timezone)::date
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

notify pgrst, 'reload schema';
