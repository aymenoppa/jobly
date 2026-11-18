-- A bank account is never charged more than the autopay limit: that invoice goes to the client to pay.
--
-- A business sets "Most to charge without asking" (settings.autopay.max_amount). A charge over it
-- waited for the office's OK, and the OK charged the saved method at once, whatever it was. For a
-- bank account the terms of 20261113001820_autopay_bank_account_terms.sql promised the client the
-- amount and date 10 days before any charge over the limit, and nothing sent that or waited for it.
--
-- Now, for a saved bank account only (a card is charged exactly as before):
--   No pull          A charge for more than the limit is never made: not by the 5-minute task, not
--                    by the office's OK, not by Charge card, not by a retry. autopay_bill, the one
--                    function every charge passes before Stripe is asked, closes it instead, and
--                    autopay_mark_sent, approve_autopay_charge, request_manual_charges and
--                    chargeable_invoices each refuse it too, so the server and web app from before
--                    this, which run on for a while after an update, can't pull one either.
--   The limit        The business's limit as it is now, or the one named in the words the client
--                    agreed to when that is lower (autopay_bank_limit): raising the limit later
--                    never takes more from a bank account than its owner agreed to. Compared with
--                    what's owed on the invoice, as the office's OK always was.
--   Instead          The charge is closed as not made (called_off, with bank_limit: the limit it
--                    was over) and its invoice is handed to the server to send the usual way
--                    (send_state, as a scheduled payment's is: claim_autopay_sends, autopay_sent).
--                    The office is told once, when it has gone or when it couldn't be sent. Then
--                    it's an unpaid invoice like any other.
--   Other reasons    A charge that waits for the office's OK for another reason (extra work, an AI
--                    assistant's Complete, visits from before autopay) still does while it's within
--                    the limit. Over it on a bank account, this rule comes first: it's closed, no
--                    OK can charge it, and because the office was to look at that invoice first, it
--                    isn't sent by itself. The office is told to look it over and send it.
--   Already waiting  A bank account's charge over the limit that waits for the OK as this arrives
--                    is closed the same way, here and at the start of every claim after
--                    (autopay_bank_limit_sweep), a row at a time, and never twice.
--   On its way       A charge whose bank payment is already on its way is left to finish: nothing
--                    new is asked of the bank, and the client isn't told to pay meanwhile.
--   The terms        The bank account paragraph says so (autopay_bank_text; core autopayBankText has
--                    the same words) and no longer promises notice. The words changed, so the
--                    version did. Nobody who agreed is asked again: this only ever takes less.
--
-- supabase/tests/autopay_bank_limit_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- The terms
-- ---------------------------------------------------------------------------------------------

-- As in 20261113001820_autopay_bank_account_terms.sql, with what happens now (core autopayBankText's
-- words, exactly). With a limit: up to it is taken, more is sent to them to pay. With none, every
-- charge is taken, and the words say so.
create or replace function private.autopay_bank_text(p_autopay jsonb) returns text
language sql immutable security definer set search_path = '' as $$
  select case when private.autopay_cap(p_autopay) is null
    then 'If you pay from a bank account: each charge is for the invoice it pays, and is taken automatically whatever its amount.'
    else 'If you pay from a bank account: charges of ' || private.money(private.autopay_cap(p_autopay))
      || ' or less are taken automatically. An invoice for more than ' || private.money(private.autopay_cap(p_autopay))
      || ' is not taken from your bank account: we send it to you to pay.'
  end
$$;

-- As in 20261113001820_autopay_bank_account_terms.sql: the bank account paragraph changed, so the
-- starter version did.
create or replace function private.autopay_terms_version(p_company uuid) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(private.autopay_of(c.settings) ->> 'terms_version', ''), 'starter-' || coalesce(nullif(c.trade_preset, ''), 'general') || '-3')
  from public.companies c where c.id = p_company
$$;

-- A version saved before this is for the paragraph as it was. Someone part way through agreeing
-- reads the words again; an agreement already made keeps its words and its version.
do $$
begin
  perform set_config('jobly.autopay', 'on', true);
  update public.companies c
  set settings = jsonb_set(c.settings, '{autopay,terms_version}',
    to_jsonb(left(regexp_replace(c.settings -> 'autopay' ->> 'terms_version', '\+bank$', ''), 34) || '+bank2'))
  where jsonb_typeof(c.settings -> 'autopay' -> 'terms_version') = 'string'
    and nullif(c.settings -> 'autopay' ->> 'terms_version', '') is not null
    and c.settings -> 'autopay' ->> 'terms_version' not like '%+bank2';
  perform set_config('jobly.autopay', 'off', true);
end $$;

-- ---------------------------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------------------------

-- Set together, only on a charge closed because it was over the limit for a bank account.
alter table public.autopay_charges add column bank_limit numeric(12, 2);
alter table public.autopay_charges add column bank_limit_at timestamptz;
-- Its invoice on the way to the client: waiting for the server, sending (claimed by one run), sent,
-- failed (it couldn't be sent, so it's the office's to send), or held (the office was to look at it
-- first for another reason, so it's theirs to look over and send). Null: nothing to send (it was
-- paid, voided or sent by the office first). send_error: why it failed or is held. send_draft:
-- whether the invoice was still a draft then, and so never sent by anyone.
alter table public.autopay_charges add column send_state text check (send_state in ('waiting', 'sending', 'sent', 'failed', 'held'));
alter table public.autopay_charges add column send_draft boolean;
alter table public.autopay_charges add column send_claimed_at timestamptz;
alter table public.autopay_charges add column send_error text check (length(send_error) <= 500);
comment on column public.autopay_charges.bank_limit is 'The most the client''s bank account is charged without them paying it themselves, when this charge was closed for being over it. Nothing was charged; the invoice goes to the client to pay.';
comment on column public.autopay_charges.send_state is 'For a charge closed over its bank limit: where its invoice is on the way to the client (waiting, sending, sent, failed, held for the office to look over).';

-- The few charges the task looks at on every run: ones waiting for the office's OK, and invoices
-- waiting to go to the client.
create index autopay_charges_approval_idx on public.autopay_charges (company_id) where status = 'needs_approval';
create index autopay_charges_send_idx on public.autopay_charges (bank_limit_at) where send_state in ('waiting', 'sending');

-- ---------------------------------------------------------------------------------------------
-- The limit for a bank account
-- ---------------------------------------------------------------------------------------------

-- Whether a saved method is a bank account, by Stripe's type for it (core isBankAccount): a US bank
-- account, or another country's bank debit (sepa_debit, acss_debit, bacs_debit, au_becs_debit).
-- Cards and Link are not.
create function private.autopay_is_bank(p_type text) returns boolean
language sql immutable set search_path = '' as $$
  select coalesce(p_type = 'us_bank_account' or p_type like '%\_debit', false)
$$;

-- The limit named in the words a client agreed to (an agreement's terms, kept as shown): the amount
-- in its bank account paragraph, as this file's words and the ones before them both write it
-- ("more than $500.00"). Null when the words name none: agreed with no limit set, or before the
-- terms had the paragraph.
create function private.autopay_agreed_cap(p_terms text) returns numeric
language sql immutable set search_path = '' as $$
  select nullif(replace((regexp_match(substring(p_terms from '.*(If you pay from a bank account:.*)$'),
                                      'more than \$([0-9][0-9,]*(?:\.[0-9]+)?)'))[1], ',', ''), '')::numeric
$$;

-- The most a client's saved method is charged when it's a bank account: the business's limit now,
-- or the one in the words the client agreed to when that's lower. Null for a card, and for a bank
-- account when neither names a limit.
create function private.autopay_bank_limit(p_company uuid, p_client uuid, p_method uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select least(
    private.autopay_cap(private.autopay_of(c.settings)),
    (select private.autopay_agreed_cap(a.terms) from public.autopay_authorizations a
     where a.company_id = p_company and a.client_id = p_client and a.revoked_at is null))
  from public.companies c
  where c.id = p_company
    and exists (select 1 from public.client_payment_methods pm
                where pm.id = p_method and pm.company_id = p_company and private.autopay_is_bank(pm.type))
$$;

-- Why such a charge is closed, as the office reads it on the client's page.
create function private.autopay_bank_limit_reason() returns text
language sql immutable set search_path = '' as $$
  select 'Over the limit for a bank account. The client pays this one themselves'
$$;

-- A charge over its bank account's limit: closed as not made, whatever it waited on, and its
-- invoice (a draft, or one still owed) handed to the server to send to the client. With p_look, a
-- reason the office was to look at it first whatever the amount (an AI assistant's Complete, visits
-- from before autopay, extra work): nothing goes to the client by itself, and the office is told
-- here, once, to look it over and send it. The answer is the one autopay_bill gives for any charge
-- it calls off.
create function private.autopay_to_client(p_charge uuid, p_limit numeric, p_look text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r public.autopay_charges;
  i public.invoices;
begin
  select * into r from public.autopay_charges where id = p_charge;
  select * into i from public.invoices where id = r.invoice_id and balance_due > 0 and status in ('draft', 'sent', 'partially_paid', 'overdue');
  update public.autopay_charges a
  set status = 'called_off', last_error = private.autopay_bank_limit_reason(), bank_limit = p_limit, bank_limit_at = now(),
      send_state = case when i.id is null then null when p_look is not null then 'held' else 'waiting' end,
      send_draft = i.status = 'draft', send_error = left(rtrim(btrim(p_look), '.'), 500),
      send_claimed_at = null, claim_token = null, locked_until = null, busy_since = null
  where a.id = p_charge;
  if i.id is not null and p_look is not null then
    perform private.autopay_notify(r.company_id, format('Send invoice #%s to %s', i.number, private.client_name(r.client_id)),
      format('%s is over the %s limit for their bank account, so it wasn''t taken from it. Look it over before you send it: %s.',
             private.money(i.balance_due), private.money(p_limit), rtrim(btrim(p_look), '.')),
      '/invoices/' || i.id);
  end if;
  return jsonb_build_object('outcome', 'called_off', 'reason', private.autopay_bank_limit_reason(), 'invoice_id', r.invoice_id, 'to_client', true);
end $$;

-- Charges waiting for the office's OK that a bank account would pay and that are over its limit:
-- closed, each once (the ones waiting as this file is applied, and any left that way since: the
-- client changed to a bank account, the limit came down, or the draft went up). One that waited for
-- another reason too (last_error says which) is the office's to look over and send. Only for a
-- client autopay would charge now: with autopay off in Settings or for the client, the charge is
-- called off the way it always was. Returns how many.
create function private.autopay_bank_limit_sweep(p_company uuid default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select a.id, a.last_error, l.lim
    from public.autopay_charges a
    join public.invoices i on i.id = a.invoice_id
    cross join lateral (
      select private.autopay_bank_limit(a.company_id, a.client_id, private.autopay_ready(a.company_id, a.client_id)) as lim
    ) l
    where a.status = 'needs_approval' and (p_company is null or a.company_id = p_company)
      and i.balance_due > l.lim
    order by a.id
    for update of a skip locked
  loop
    perform private.autopay_to_client(r.id, r.lim, r.last_error);
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------------------------
-- The task's functions
-- ---------------------------------------------------------------------------------------------
/**
 * As in 20261113000900_visit_extras.sql, plus: once the invoice is there, a bank account is never
 * asked for more than its limit (autopay_bank_limit). Whatever made the charge (a finished visit, a
 * month, the office's OK or its Charge card, a retry on a method agreed to since), it's closed as
 * not made and its invoice goes to the client to pay (autopay_to_client), or to the office to look
 * over and send when it would have waited for their look for another reason. The answer is
 * 'called_off', as for any charge this calls off, with to_client.
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
  v_bank_limit numeric;
  v_over boolean;
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

  -- 3b. A bank account, and more than its limit: never charged, by anyone's say. It comes before
  -- every reason to ask the office first, because their OK couldn't charge it either; a draft the
  -- office was to look at for one of those reasons is theirs to look over and send (step 4), and
  -- anything else goes to the client. Not while a bank payment for the invoice is already on its
  -- way (this charge's own, its answer lost, or the client's from Stripe's page): the server
  -- follows that one and asks the bank for nothing new (chargeInvoiceAutomatically), and telling
  -- the client to pay meanwhile could have them pay twice.
  v_bank_limit := private.autopay_bank_limit(r.company_id, r.client_id, v_pm);
  v_over := coalesce(i.balance_due > v_bank_limit, false)
    and not exists (select 1 from public.stripe_invoices s where s.invoice_id = i.id and s.status = 'processing'
                      and (s.detached_at is null or s.detached_at > now() - interval '30 days'));
  if v_over and not (i.status = 'draft' and r.source = 'autopay') then
    return private.autopay_to_client(r.id, v_bank_limit);
  end if;

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
      if v_over then
        return private.autopay_to_client(r.id, v_bank_limit, r.held);
      end if;
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
        if v_over then
          return private.autopay_to_client(r.id, v_bank_limit, v_reason);
        end if;
        update public.autopay_charges
        set status = 'needs_approval', last_error = v_reason, claim_token = null, locked_until = null, busy_since = null
        where id = r.id;
        return jsonb_build_object('outcome', 'needs_approval', 'reason', v_reason, 'invoice_id', i.id);
      end if;
    end if;
    if v_over then
      return private.autopay_to_client(r.id, v_bank_limit);
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

/**
 * As in 20261101000100_autopay.sql, plus: false for a bank account asked for more than its limit.
 * This is the last step before Stripe is told to charge, so a server from before this file that had
 * the charge in hand as it was applied stops here; its next claim closes it (autopay_bill).
 *
 * Mark a claimed charge's draft invoice sent (no email), once the Stripe invoice for it is made.
 * False, and nothing changes, unless the caller holds the claim and the invoice is still there,
 * still owed and still for exactly the amount Stripe will charge (p_amount_cents: the Stripe
 * invoice's lines total, before any customer balance; a charge carries no tip).
 */
create or replace function public.autopay_mark_sent(p_charge uuid, p_token uuid, p_amount_cents integer) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  r public.autopay_charges;
  i public.invoices;
begin
  select * into r from public.autopay_charges where id = p_charge for update;
  if not found or p_token is null or r.status <> 'charging' or r.claim_token is distinct from p_token or r.invoice_id is null then
    return false;
  end if;
  select * into i from public.invoices where id = r.invoice_id for update;
  if not found or i.status not in ('draft', 'sent', 'partially_paid', 'overdue') or round(i.balance_due * 100) is distinct from p_amount_cents then
    return false;
  end if;
  if i.balance_due > private.autopay_bank_limit(r.company_id, r.client_id, r.payment_method_id) then
    return false;
  end if;
  update public.invoices set status = 'sent' where id = i.id and status = 'draft';
  update public.autopay_charges set locked_until = now() + interval '5 minutes' where id = r.id;
  return true;
end $$;

/**
 * As in 20261101000100_autopay.sql, plus: each run first closes any charge waiting for the office's
 * OK that a bank account would pay and that is over its limit (autopay_bank_limit_sweep), so one is
 * never left asking for an OK that can't charge it. A problem there never stops the claim.
 *
 * The task's batch: due charges, and ones whose worker stopped. The task itself stops a row on its
 * 6th claim after asking Stripe; this only catches rows a crashing task never got to. A failed or
 * waiting charge whose invoice has a bank payment on its way in Stripe (the client paying it on
 * Stripe's page) waits: once it clears the invoice is paid, and if it bounces it's tried as usual.
 */
create or replace function public.claim_autopay_charges(p_limit integer default 25, p_company uuid default null)
returns setof public.autopay_charges
language plpgsql security definer set search_path = '' as $$
declare
  v_token uuid := gen_random_uuid();
begin
  begin
    perform private.autopay_bank_limit_sweep(p_company);
  exception when others then
    raise warning 'autopay: %', sqlerrm;
  end;

  update public.autopay_charges
  set status = 'called_off', claim_token = null, locked_until = null, busy_since = null,
      last_error = 'Stopped after 8 tries. Check the invoice and Stripe'
  where status = 'charging' and locked_until < now() and attempts >= 8
    and (p_company is null or company_id = p_company);

  return query
  update public.autopay_charges a
  set status = 'charging', locked_until = now() + interval '5 minutes', claim_token = v_token, attempts = a.attempts + 1
  where a.id in (
    select x.id from public.autopay_charges x
    where ((x.status in ('waiting', 'failed') and x.due_at <= now()
            and not exists (select 1 from public.stripe_invoices s
                            where s.invoice_id = x.invoice_id and s.status = 'processing' and s.detached_at is null))
           or (x.status = 'charging' and x.locked_until < now()))
      and (p_company is null or x.company_id = p_company)
    order by x.due_at
    limit least(greatest(coalesce(p_limit, 25), 1), 100)
    for update skip locked
  )
  returning a.*;
end $$;

-- ---------------------------------------------------------------------------------------------
-- The office's functions
-- ---------------------------------------------------------------------------------------------

/**
 * As in 20261101000100_autopay.sql, plus: the OK never charges a bank account more than its limit.
 * Such a charge is closed and its invoice goes to the client to pay instead (autopay_to_client),
 * whichever screen the OK came from; the caller reads the charge to see which happened.
 *
 * Approve charge: a charge over the limit goes ahead now.
 */
create or replace function public.approve_autopay_charge(p_charge uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.autopay_charges;
  v_bank_limit numeric;
begin
  select * into r from public.autopay_charges where id = p_charge for update;
  if not found or not (private.has_role(r.company_id, '{owner,admin,office}') and private.has_perm(r.company_id, 'invoices')) then
    raise exception 'Only the office with the invoices area can do that' using errcode = '42501';
  end if;
  if r.status <> 'needs_approval' then
    raise exception 'This charge isn''t waiting for your OK' using errcode = '22023';
  end if;
  -- The method autopay would charge now. With none (autopay off in Settings or for the client), the
  -- OK goes on as before and autopay_bill calls the charge off, saying why. The office has looked
  -- by pressing OK, so the invoice goes to the client.
  v_bank_limit := private.autopay_bank_limit(r.company_id, r.client_id, private.autopay_ready(r.company_id, r.client_id));
  if (select i.balance_due from public.invoices i where i.id = r.invoice_id) > v_bank_limit then
    perform private.autopay_to_client(r.id, v_bank_limit);
    return;
  end if;
  update public.autopay_charges
  set status = 'waiting', due_at = now(), last_error = null, approved_by = (select auth.uid()), approved_at = now(),
      approved_amount = (select i.balance_due from public.invoices i where i.id = r.invoice_id)
  where id = r.id;
end $$;

/**
 * As in 20261101000300_manual_charges.sql, plus one more answer:
 *
 *   bank_limit   the client pays from a bank account and this is more than its limit: nothing is
 *                queued, and the reason says to send it to them to pay
 *
 * Charge card, for one invoice or up to 50: each is queued as a manual charge due now, approved by
 * the caller for the amount they saw (p_amounts, dollars, one for each of p_invoices), to the card
 * the client agreed to, and the task charges it. Owners, admins and the office with the invoices
 * area. Says for each invoice, in the order given (an invoice given twice counts once, with its
 * first amount): queued, not_found, autopay_off, not_owed, in_progress, no_card, bank_limit or
 * changed, with the reason.
 */
create or replace function public.request_manual_charges(p_company uuid, p_invoices uuid[], p_amounts numeric[])
returns table (invoice_id uuid, outcome text, reason text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_user uuid := (select auth.uid());
  v_on boolean;
  v_id uuid;
  v_amount numeric;
  v_live text;
  v_detail text;
  v_pm uuid;
  v_charge uuid;
  v_bank_limit numeric;
  i public.invoices;
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'invoices')) then
    raise exception 'Only the office with the invoices area can do that' using errcode = '42501';
  end if;
  if coalesce(cardinality(p_invoices), 0) > 50 then
    raise exception 'Choose up to 50 invoices at a time' using errcode = '22023';
  end if;
  if coalesce(cardinality(p_amounts), 0) <> coalesce(cardinality(p_invoices), 0) then
    raise exception 'Send the amount you saw for each invoice' using errcode = '22023';
  end if;
  v_on := private.manual_charges_on(p_company);

  for v_id, v_amount in
    select x.u, x.a from (
      select distinct on (t.u) t.u, t.a, t.n from unnest(p_invoices, p_amounts) with ordinality t(u, a, n) where t.u is not null order by t.u, t.n
    ) x order by x.n
  loop
    invoice_id := v_id;
    reason := null;
    -- Locked, so two presses at once queue one charge.
    select * into i from public.invoices x where x.id = v_id and x.company_id = p_company for update;
    if not found then
      outcome := 'not_found';
      reason := 'Invoice not found';
    elsif not v_on then
      outcome := 'autopay_off';
      reason := case when exists (select 1 from public.companies c where c.id = p_company and private.autopay_of(c.settings) -> 'enabled' = 'true'::jsonb)
        then 'Update your Stripe key on the Apps page' else 'Turn on autopay in Settings → Payments' end;
    elsif i.status not in ('draft', 'sent', 'partially_paid', 'overdue') or i.balance_due <= 0 then
      outcome := 'not_owed';
      reason := case i.status when 'paid' then 'It''s paid' when 'void' then 'It was voided' when 'written_off' then 'It was written off' else 'Nothing is owed on it' end;
    elsif private.stripe_collects(i.id) then
      outcome := 'not_owed';
      reason := 'It was made in Stripe. Charge it there';
    else
      select l.live_status, l.live_detail into v_live, v_detail from private.live_charge(i.id) l;
      v_pm := private.autopay_ready(p_company, i.client_id);
      v_bank_limit := private.autopay_bank_limit(p_company, i.client_id, v_pm);
      if v_live is not null then
        outcome := 'in_progress';
        reason := v_detail;
      elsif v_pm is null then
        outcome := 'no_card';
        reason := case
          when exists (select 1 from public.autopay_authorizations a where a.company_id = p_company and a.client_id = i.client_id and a.revoked_at is null and a.paused_at is not null)
            then 'Autopay is paused for this client'
          when exists (select 1 from public.autopay_authorizations a where a.company_id = p_company and a.client_id = i.client_id and a.revoked_at is null)
            then 'The client''s card needs updating'
          else 'No saved card the client agreed to' end;
      -- A bank account is never charged more than its limit, whoever asks.
      elsif i.balance_due > v_bank_limit then
        outcome := 'bank_limit';
        reason := format('It''s over the %s limit for their bank account, so it isn''t taken from it. Send it to them to pay', private.money(v_bank_limit));
      -- The office confirmed an amount: a line changed since (or a payment) asks them again.
      elsif round(v_amount, 2) is distinct from i.balance_due then
        outcome := 'changed';
        reason := format('The amount changed to %s. Check it and try again', private.money(i.balance_due));
      else
        insert into public.autopay_charges (company_id, client_id, source, invoice_id, payment_method_id, due_at, status,
          approved_by, approved_at, approved_amount, requested_by)
        values (p_company, i.client_id, 'manual', i.id, v_pm, now(), 'waiting', v_user, now(), i.balance_due, v_user)
        returning id into v_charge;
        perform private.emit(p_company, 'autopay.charge_requested', 'invoice', i.id,
          format('Charging %s to %s''s %s for invoice #%s', private.money(i.balance_due), private.client_name(i.client_id), private.method_label_of(v_pm), i.number),
          jsonb_build_object('charge_id', v_charge, 'number', i.number, 'amount', i.balance_due, 'card', private.method_label_of(v_pm),
            'client_id', i.client_id, 'requested_by', v_user));
        outcome := 'queued';
      end if;
    end if;
    return next;
  end loop;
end $$;

/**
 * As in 20261101000300_manual_charges.sql, plus: not an invoice over the limit of the bank account
 * that would pay it. Charge card isn't offered for it, on the list or on the invoice.
 *
 * The invoices Charge card can charge now (owners, admins and the office with the invoices area):
 * owed, and their client has a card they agreed to be charged, newest first, with the card's name and
 * what's collecting it already, if anything (live_charge: in_progress, live_status and live_detail;
 * the list shows it, not to be picked). Not one made in Stripe, which is charged there
 * (stripe_collects). Nothing while autopay is off or the Stripe key can't charge cards. The list (no
 * p_invoice) leaves drafts out, which haven't gone to the client yet; asked about one invoice (the
 * invoice page's button), a draft counts.
 */
create or replace function public.chargeable_invoices(p_company uuid, p_invoice uuid default null)
returns table (id uuid, number bigint, client_id uuid, client_name text, balance_due numeric, due_on date, status text, card text,
               in_progress boolean, live_status text, live_detail text)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
begin
  if not (private.has_role(p_company, '{owner,admin,office}') and private.has_perm(p_company, 'invoices')) then
    raise exception 'Only the office with the invoices area can do that' using errcode = '42501';
  end if;
  if not private.manual_charges_on(p_company) then
    return;
  end if;
  return query
    select i.id, i.number, i.client_id, c.display_name, i.balance_due, i.due_on, i.status, private.method_label_of(r.pm),
           l.live_status is not null, l.live_status, l.live_detail
    from public.invoices i
    join public.clients c on c.id = i.client_id
    cross join lateral (select private.autopay_ready(p_company, i.client_id) as pm) r
    cross join lateral private.live_charge(i.id) l
    where i.company_id = p_company and r.pm is not null and i.balance_due > 0
      and (i.status in ('sent', 'partially_paid', 'overdue') or (p_invoice is not null and i.status = 'draft'))
      and (p_invoice is null or i.id = p_invoice)
      and not private.stripe_collects(i.id)
      and not coalesce(i.balance_due > private.autopay_bank_limit(p_company, i.client_id, r.pm), false)
    order by i.created_at desc, i.id
    -- shortcut: the newest 500 only; page it if a company ever has more owed on saved cards.
    limit 500;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Who's told what
-- ---------------------------------------------------------------------------------------------

-- As in 20261101000300_manual_charges.sql, plus: a charge closed over a bank account's limit
-- (bank_limit) has its Stripe invoice brought in step like any charge called off, and tells the
-- office nothing here. They're told once, when its invoice has gone to the client or couldn't be
-- sent (autopay_sent).
--
-- paid (from charging or processing): the receipt, but not between tries after a busy Stripe
-- (charging, no claim, busy_since set): autopay charged nothing then, so the client paid its Stripe
-- invoice on Stripe's page themselves. failed and needs_client: the client's notice,
-- the office's notification and autopay.failed, only when it's a new failure (so a claim released
-- back to 'failed' tells nobody twice). needs_approval: the office. called_off with an invoice left
-- as a draft or still owed: its Stripe invoice is brought in step (syncStripeInvoice voids a
-- charge_automatically one nothing will pay now) and the office is told, unless it did it itself.
-- Not when it was paid another way and that payment is still being booked (the server calls a
-- charge off just before it books the client paying autopay's Stripe invoice with another card).
create or replace function private.autopay_charge_status() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_client text := private.client_name(new.client_id);
  v_link text := case when new.invoice_id is not null then '/invoices/' || new.invoice_id else '/clients/' || new.client_id end;
  v_tz text;
  v_card text := private.method_label_of(new.payment_method_id);
  v_bank boolean;
  v_body text;
  i public.invoices;
begin
  if new.invoice_id is not null then
    select * into i from public.invoices where id = new.invoice_id;
  end if;
  select coalesce(c.timezone, 'UTC') into v_tz from public.companies c where c.id = new.company_id;

  if new.status = 'paid' and (old.status = 'processing'
                              or (old.status = 'charging' and (old.claim_token is not null or old.busy_since is null))) then
    insert into public.outbox (company_id, topic, payload)
    values (new.company_id, 'autopay.receipt', jsonb_build_object('charge_id', new.id));

  elsif new.status in ('failed', 'needs_client')
        and (new.failures > old.failures or (new.status = 'needs_client' and old.status in ('charging', 'processing'))) then
    insert into public.outbox (company_id, topic, payload)
    values (new.company_id, 'autopay.notice', jsonb_build_object('charge_id', new.id, 'status', new.status, 'failures', new.failures));
    if new.status = 'failed' then
      perform private.autopay_notify(new.company_id, format('Autopay failed: %s', v_client),
        format('Invoice #%s · %s. We''ll try again on %s.', i.number, rtrim(coalesce(new.last_error, 'The card was declined'), '.'),
               to_char(new.due_at at time zone v_tz, 'Mon FMDD')),
        v_link);
    else
      v_bank := old.status = 'processing'
        or exists (select 1 from public.client_payment_methods pm where pm.id = new.payment_method_id and pm.type = 'us_bank_account');
      v_body := case
        when new.failures > old.failures and v_bank then 'Their bank payment didn''t go through, so autopay is paused until they update it.'
        when new.failures > old.failures and new.source = 'manual' then 'The card was declined, so they were sent the Pay link and a way to update their card.'
        when new.failures > old.failures then 'The card was declined twice, so autopay is paused until they update it.'
        when new.last_error is null or new.decline_code in ('authentication_required', 'invoice_payment_intent_requires_action', 'requires_action')
          then 'Their bank wants them to confirm the payment.'
        else new.last_error
      end;
      perform private.autopay_notify(new.company_id, format('Autopay needs %s', v_client), v_body, v_link);
    end if;
    if new.invoice_id is not null then
      perform private.emit(new.company_id, 'autopay.failed', 'invoice', new.invoice_id,
        format('Autopay failed for invoice #%s (%s)', i.number, v_client),
        jsonb_build_object('client_id', new.client_id, 'card', v_card, 'reason', new.last_error, 'status', new.status));
    end if;

  elsif new.status = 'needs_approval' then
    perform private.autopay_notify(new.company_id, format('Approve a %s charge for %s', private.money(i.balance_due), v_client),
      coalesce(new.last_error, 'It''s over your autopay limit, so it waits for your OK.'), v_link);

  elsif new.status = 'called_off' and new.bank_limit is not null then
    if i.id is not null and i.balance_due > 0 and i.status in ('draft', 'sent', 'partially_paid', 'overdue') then
      perform private.autopay_enqueue_stripe(new.company_id, new.invoice_id);
    end if;

  elsif new.status = 'called_off' and new.invoice_id is not null and i.id is not null
        and new.last_error is distinct from 'The invoice was deleted' then
    if i.status = 'draft' then
      perform private.autopay_enqueue_stripe(new.company_id, new.invoice_id);
      if new.last_error is null or new.last_error not in ('Called off by the office', 'The invoice went back to draft') then
        perform private.autopay_notify(new.company_id, format('Send invoice #%s to %s the usual way', i.number, v_client), new.last_error, v_link);
      end if;
    elsif i.status in ('sent', 'partially_paid', 'overdue') and i.balance_due > 0 and new.last_error is distinct from 'Paid another way' then
      perform private.autopay_enqueue_stripe(new.company_id, new.invoice_id);
      if new.last_error is null or new.last_error not in ('Called off by the office', 'Sent the usual way') then
        perform private.autopay_notify(new.company_id, format('Invoice #%s for %s wasn''t charged', i.number, v_client),
          format('%s. It''s owed as usual; send a reminder if they need the Pay link.', rtrim(coalesce(new.last_error, 'Autopay was called off'), '.')), v_link);
      end if;
    end if;
  end if;
  return null;
end $$;

-- ---------------------------------------------------------------------------------------------
-- The invoice goes to the client
-- ---------------------------------------------------------------------------------------------

/**
 * The invoices of charges closed over a bank account's limit that are waiting to go to the client,
 * claimed for this run (apps/api/src/services/bankLimit.ts sends each the usual way, once). One that
 * is paid, voided, written off or deleted by now, or that was a draft and isn't any more (the office
 * sent it), has nothing left to send. One with a bank payment on its way waits: once that clears
 * the invoice is paid, and if it bounces it's sent then. One a run claimed and never answered for
 * (its server stopped) may or may not have gone: it's never sent a second time, and the office is
 * asked to look. send_draft comes back so the server can check once more just before it sends.
 */
create function public.claim_autopay_sends(p_limit integer default 20, p_company uuid default null)
returns table (id uuid, company_id uuid, invoice_id uuid, bank_limit numeric, send_draft boolean)
language plpgsql security definer set search_path = '' as $$
declare
  v_stale uuid;
begin
  update public.autopay_charges a set send_state = null, send_claimed_at = null
  where a.send_state = 'waiting' and (p_company is null or a.company_id = p_company)
    and not exists (select 1 from public.invoices i where i.id = a.invoice_id and i.balance_due > 0
                      and (i.status = 'draft' or (i.status in ('sent', 'partially_paid', 'overdue') and a.send_draft is not true)));
  for v_stale in
    select a.id from public.autopay_charges a
    where a.send_state = 'sending' and a.send_claimed_at < now() - interval '30 minutes' and (p_company is null or a.company_id = p_company)
    for update skip locked
  loop
    perform public.autopay_sent(v_stale, false, 'The server stopped while it was sending it, so check whether it went');
  end loop;
  return query
  update public.autopay_charges a set send_state = 'sending', send_claimed_at = now()
  where a.id in (select x.id from public.autopay_charges x
                 where x.send_state = 'waiting' and x.invoice_id is not null and (p_company is null or x.company_id = p_company)
                   and not exists (select 1 from public.stripe_invoices s where s.invoice_id = x.invoice_id and s.status = 'processing'
                                     and (s.detached_at is null or s.detached_at > now() - interval '30 days'))
                 order by x.bank_limit_at limit least(greatest(coalesce(p_limit, 20), 1), 100) for update skip locked)
  returning a.id, a.company_id, a.invoice_id, a.bank_limit, a.send_draft;
end $$;

/**
 * How sending a claimed invoice went, and the office is told, once: that it went to the client to
 * pay and why, or that it couldn't be sent and is theirs to send. Nothing when the caller's claim
 * is gone.
 */
create function public.autopay_sent(p_charge uuid, p_sent boolean, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r public.autopay_charges;
  i public.invoices;
  v_why text;
begin
  update public.autopay_charges
  set send_state = case when p_sent then 'sent' else 'failed' end,
      send_error = case when p_sent then null else left(coalesce(nullif(rtrim(btrim(p_error), '.'), ''), 'It couldn''t be sent'), 500) end
  where id = p_charge and send_state = 'sending'
  returning * into r;
  if not found then
    return;
  end if;
  select * into i from public.invoices where id = r.invoice_id;
  if i.id is null then
    return;
  end if;
  v_why := format('%s is over the %s limit for their bank account, so it wasn''t taken from it.', private.money(i.balance_due), private.money(r.bank_limit));
  if p_sent then
    perform private.autopay_notify(r.company_id, format('Invoice #%s went to %s to pay', i.number, private.client_name(r.client_id)),
      v_why || ' They were sent the invoice to pay themselves.', '/invoices/' || i.id);
  else
    perform private.autopay_notify(r.company_id, format('Send invoice #%s to %s', i.number, private.client_name(r.client_id)),
      v_why || format(' It couldn''t be sent to them (%s), so send it from the invoice.', r.send_error), '/invoices/' || i.id);
  end if;
end $$;

/** The server found a claimed invoice sent by the office, or settled, just before sending it: it isn't sent, and nobody needs telling. */
create function public.autopay_send_called_off(p_charge uuid) returns void
language sql security definer set search_path = '' as $$
  update public.autopay_charges set send_state = null, send_claimed_at = null where id = p_charge and send_state = 'sending'
$$;

-- ---------------------------------------------------------------------------------------------
-- Who calls what
-- ---------------------------------------------------------------------------------------------

revoke all on function private.autopay_is_bank(text), private.autopay_agreed_cap(text), private.autopay_bank_limit(uuid, uuid, uuid),
  private.autopay_bank_limit_reason(), private.autopay_to_client(uuid, numeric, text), private.autopay_bank_limit_sweep(uuid) from public;
revoke execute on function public.claim_autopay_sends(integer, uuid), public.autopay_sent(uuid, boolean, text), public.autopay_send_called_off(uuid)
  from public, anon, authenticated;
grant execute on function public.claim_autopay_sends(integer, uuid), public.autopay_sent(uuid, boolean, text), public.autopay_send_called_off(uuid)
  to service_role;

-- ---------------------------------------------------------------------------------------------
-- Charges already waiting
-- ---------------------------------------------------------------------------------------------

-- A bank account's charge over the limit that waits for the office's OK right now: closed, and its
-- invoice handed to the server to send. Only those rows are touched, each locked by itself.
do $$
declare
  v_count integer := private.autopay_bank_limit_sweep();
begin
  raise notice 'autopay: % charge(s) over a bank account''s limit were waiting for an OK and go to the client instead', v_count;
end $$;

notify pgrst, 'reload schema';
