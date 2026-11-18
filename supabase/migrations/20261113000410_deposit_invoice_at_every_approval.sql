-- A deposit asked for on a quote gets its invoice as the client approves, whether or not the
-- business takes payments online. Until now only a business with Stripe got one (the client was
-- sent on to pay it); without Stripe, approval made nothing, so no invoice showed the deposit as
-- owed and nobody was reminded of it.
--
--   hub_deposit_invoice   takes p_online: whether the client is sent on to pay it online now. It
--                         makes the same invoice either way (sent, due on the payment terms, never
--                         a late fee: 20261107000100_deposit_invoice_terms.sql), so the office
--                         records cash or a cheque against it like any other.
--   Telling the office    Not paid online: the people who look after money are told on the bell
--                         as it's made. Sent on to pay online: they're told once if it's still
--                         unpaid an hour later (tell_unpaid_deposits, hourly), since most are paid
--                         in the next minute. quotes.deposit_told_at keeps it to once.
--
-- p_online defaults to true, which is what the server before this one means when it calls with two
-- arguments (it only ever asked when Stripe was connected). Deposit invoices made before this are
-- marked as told, so the first hourly run says nothing about old ones.
-- supabase/tests/deposit_at_approval_test.sql covers it.

alter table public.quotes add column deposit_told_at timestamptz;
comment on column public.quotes.deposit_told_at is 'When the office was told its deposit invoice (deposit_invoice_id) was unpaid, or when that was settled without telling anyone. Null until then.';

-- Nothing else about these quotes changes, so their triggers stay out of it.
alter table public.quotes disable trigger user;
update public.quotes set deposit_told_at = now() where deposit_invoice_id is not null;
alter table public.quotes enable trigger user;

-- The quotes the hourly run still has to look at: a handful at any time.
create index quotes_deposit_untold_idx on public.quotes (deposit_invoice_id) where deposit_invoice_id is not null and deposit_told_at is null;

-- A bell notification about a quote's unpaid deposit invoice, for the people who look after money.
create function private.deposit_unpaid_notify(p_quote uuid, p_title text, p_body text) returns void
language sql security definer set search_path = '' as $$
  insert into public.notifications (company_id, user_id, kind, title, body, link)
  select q.company_id, u, 'invoice',
         left(format(p_title, coalesce(nullif(private.client_name(q.client_id), ''), 'The client'), private.money(i.balance_due), q.number), 300),
         format(p_body, i.number), '/invoices/' || i.id
  from public.quotes q
  join public.invoices i on i.id = q.deposit_invoice_id
  cross join lateral private.money_office(q.company_id) u
  where q.id = p_quote
$$;
revoke all on function private.deposit_unpaid_notify(uuid, text, text) from public;

-- As in 20261107000100_deposit_invoice_terms.sql, plus p_online and telling the office.
drop function public.hub_deposit_invoice(uuid, uuid);
create function public.hub_deposit_invoice(p_company uuid, p_quote uuid, p_online boolean default true) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  q public.quotes;
  v_today date;
  v_terms integer;
  v_invoice uuid;
begin
  select * into q from public.quotes
   where company_id = p_company and id = p_quote and status in ('approved', 'converted')
   for update;
  if not found then
    return null;
  end if;
  if q.deposit_invoice_id is not null then
    return q.deposit_invoice_id;
  end if;
  if least(q.deposit_amount, q.total) <= 0 then
    return null;
  end if;
  select (now() at time zone coalesce(c.timezone, 'UTC'))::date,
         coalesce((select cl.payment_terms_days from public.clients cl where cl.id = q.client_id), (c.settings ->> 'payment_terms_days')::integer, 30)
    into v_today, v_terms
    from public.companies c where c.id = p_company;
  insert into public.invoices (company_id, client_id, job_id, kind, subject, issued_on, due_on, tax_rate)
  values (p_company, q.client_id,
          coalesce(q.change_order_for, (select j.id from public.jobs j where j.company_id = p_company and j.quote_id = q.id order by j.created_at limit 1)),
          'deposit', 'Deposit: ' || q.title, v_today, v_today + v_terms, 0)
  returning id into v_invoice;
  insert into public.invoice_line_items (company_id, invoice_id, name, quantity, unit, unit_price, taxable, sort)
  values (p_company, v_invoice, 'Deposit for ' || q.title, 1, 'ea', least(q.deposit_amount, q.total), false, 0);
  -- Sent once its line is on, so it goes out (and to Stripe) for what it asks.
  update public.invoices set status = 'sent' where id = v_invoice;
  -- Not paid online now: the office is told at once. Otherwise tell_unpaid_deposits looks in an hour.
  update public.quotes set deposit_invoice_id = v_invoice, deposit_told_at = case when coalesce(p_online, true) then null else now() end where id = q.id;
  if not coalesce(p_online, true) then
    perform private.deposit_unpaid_notify(q.id, '%s owes a %s deposit on quote #%s',
      'They approved it online. Invoice #%s is for the deposit: record the payment on it when it comes in.');
  end if;
  return v_invoice;
end $$;
revoke execute on function public.hub_deposit_invoice(uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function public.hub_deposit_invoice(uuid, uuid, boolean) to service_role;

/**
 * Hourly (tasks.ts): each deposit invoice made as a client approved and was sent on to pay online,
 * an hour or more ago, that nobody has been told about. Still owed: the people who look after money
 * are told, once. Paid, voided or written off: nothing to say, and it isn't looked at again. While a
 * bank payment for it is on its way it's left for the next hour. Returns how many were told about.
 */
create function public.tell_unpaid_deposits() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select q.id, i.status, i.balance_due
      from public.quotes q
      join public.invoices i on i.id = q.deposit_invoice_id
     where q.deposit_invoice_id is not null and q.deposit_told_at is null
       and i.created_at < now() - interval '1 hour'
       and not exists (select 1 from public.stripe_invoices s where s.invoice_id = i.id and s.status = 'processing')
     for update of q skip locked
  loop
    update public.quotes set deposit_told_at = now() where id = r.id;
    if r.status in ('sent', 'partially_paid', 'overdue') and r.balance_due > 0 then
      perform private.deposit_unpaid_notify(r.id, '%s hasn''t paid the %s deposit on quote #%s',
        'They approved it online but the deposit isn''t paid yet. Invoice #%s is for it.');
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;
revoke execute on function public.tell_unpaid_deposits() from public, anon, authenticated;
grant execute on function public.tell_unpaid_deposits() to service_role;

notify pgrst, 'reload schema';
