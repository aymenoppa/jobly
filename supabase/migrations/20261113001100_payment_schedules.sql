-- A quote can carry a payment schedule, and it carries to the job.
--
-- Until now a quote asked for one deposit (an amount or a percent), and a job was progress-billed by
-- hand. Now a quote can say how it's paid: payments, each a percent of the total, an amount, or (the
-- last one only) the rest, and when each is due:
--
--   approval      as the client approves: the deposit. It works exactly as the deposit always has:
--                 quotes.deposit_amount (and deposit_percent, for a percent) follow the schedule, so
--                 the Client Hub's deposit invoice (hub_deposit_invoice), the contract's {Deposit}
--                 and an older app or server all see it as the deposit.
--   date          on a day, checked by the hourly task in the company's time zone.
--   work_starts   when one of the job's visits goes in progress (or is finished first): a trigger
--                 on visits, and the hourly task in case that didn't make it.
--   work_done     the job's final invoice, which the existing flow already makes (the job asks for
--                 its invoice when its last visit is finished) and which takes off everything billed
--                 before it, so it bills what's left.
--   by_hand       when the office invoices it, from the job.
--
-- quotes.payment_schedule holds the rows as the office writes them (null: no schedule). Saved, they
-- have to come to the quote's total (private.schedule_problem: the editor and core money.ts say the
-- same). A total that changes afterwards (lines, the option shown) doesn't touch them: percents
-- follow it, and amounts that no longer fit are flagged on the quote. As the quote is approved
-- (however: the Hub, the office, convert_quote_to_job, any server) each payment's amount for the
-- total signed is kept with the approval (approval.payment_schedule), the last taking what's left,
-- so the signed copy never moves.
--
-- The job made from it gets job_installments, one per payment, from that copy. Each later payment
-- becomes an invoice when its moment comes, made by create_invoice_for_job (a progress invoice for
-- its amount before tax, so with its tax it comes to the payment; a deposit invoice, untaxed as
-- deposits are, for one due at approval), so its rules hold: nothing passes the contract, retainage
-- and the taxed share are as for any progress invoice, and the final invoice takes each off, so the
-- invoices come to the quote's total. One that's made automatically is a draft and the people who look after money are
-- told ("Payment 2 of 3 for job #12 is ready to send"), unless the company has "Send scheduled
-- payments to clients by themselves" on (settings.payment_schedule.send, off unless set): then the
-- server sends it the usual way (installment_sends). Autopay is as it was: it charges the invoices
-- it makes itself, never a progress invoice, so no card is charged for one of these.
--
-- Never twice: a payment's invoice is kept on it (invoice_id), and once it has been made (made_at)
-- it's never made again by itself. One whose invoice was voided or deleted is made again only by
-- hand (invoice_installment). Once the job has its final invoice, the payments not invoiced yet are
-- on it, and none is made after.
--
-- supabase/tests/payment_schedule_test.sql covers it.

alter table public.quotes add column payment_schedule jsonb;
comment on column public.quotes.payment_schedule is 'How the quote is paid: [{kind: percent|amount|rest, value, due: approval|date|work_starts|work_done|by_hand, on}], null for none. Kept with the approval with each payment''s amount (approval.payment_schedule).';

-- ---------------------------------------------------------------------------------------------
-- The sums (core money.ts scheduleAmounts and scheduleProblem do the same)
-- ---------------------------------------------------------------------------------------------

-- What's wrong with the rows themselves, whatever the total, or null.
create function private.schedule_shape_problem(p_rows jsonb) returns text
language plpgsql immutable set search_path = '' as $$
declare
  r record;
  v_n integer;
  v_value numeric;
  v_which text;
begin
  if p_rows is null then
    return null;
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    return 'A payment schedule is a list of payments.';
  end if;
  v_n := jsonb_array_length(p_rows);
  if v_n > 12 then
    return 'A payment schedule has 12 payments at most.';
  end if;
  for r in select e.value as row, e.ordinality as i from jsonb_array_elements(p_rows) with ordinality e loop
    v_which := 'Payment ' || r.i;
    if jsonb_typeof(r.row) <> 'object' then
      return v_which || ' needs an amount.';
    end if;
    if coalesce(r.row ->> 'due', '') not in ('approval', 'date', 'work_starts', 'work_done', 'by_hand') then
      return v_which || ' needs to say when it''s due.';
    end if;
    if r.row ->> 'due' = 'date' then
      if coalesce(r.row ->> 'on', '') !~ '^\d{4}-\d{2}-\d{2}$' then
        return v_which || ' needs its date.';
      end if;
      begin
        perform (r.row ->> 'on')::date;
      exception when others then
        return v_which || ' needs its date.';
      end;
    end if;
    if r.row ->> 'kind' = 'rest' and r.i <> v_n then
      return 'Only the last payment can be the rest.';
    end if;
    if coalesce(r.row ->> 'kind', '') not in ('percent', 'amount', 'rest') then
      return v_which || ' needs an amount.';
    end if;
    if r.row ->> 'kind' in ('percent', 'amount') then
      if jsonb_typeof(r.row -> 'value') is distinct from 'number' then
        return case r.row ->> 'kind' when 'percent' then v_which || ' needs a percent above 0, up to 100.' else v_which || ' needs an amount.' end;
      end if;
      v_value := (r.row ->> 'value')::numeric;
      if r.row ->> 'kind' = 'percent' and not (v_value > 0 and v_value <= 100) then
        return v_which || ' needs a percent above 0, up to 100.';
      end if;
      if r.row ->> 'kind' = 'amount' and not (v_value > 0 and v_value <= 100000000) then
        return v_which || ' needs an amount.';
      end if;
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_rows) e where e.value ->> 'due' = 'approval') > 1 then
    return 'Only one payment can be due when the quote is approved.';
  end if;
  if (select count(*) from jsonb_array_elements(p_rows) e where e.value ->> 'due' = 'work_done') > 1 then
    return 'Only one payment can be due when the work is done.';
  end if;
  return null;
end $$;

/**
 * Each payment's amount for a total (rows of a schedule private.schedule_shape_problem passes): a
 * percent is round(total × percent / 100, 2), an amount is itself, none is more than what's still
 * left, and the last is what's left, so they always come to the total. The rows come back as they
 * were, each with its "amount".
 */
create function private.schedule_amounts(p_rows jsonb, p_total numeric) returns jsonb
language plpgsql immutable set search_path = '' as $$
declare
  v_total numeric := greatest(round(coalesce(p_total, 0), 2), 0);
  v_left numeric;
  v_n integer;
  v_raw numeric;
  v_amount numeric;
  v_out jsonb := '[]';
  r record;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return null;
  end if;
  v_left := v_total;
  v_n := jsonb_array_length(p_rows);
  for r in select e.value as row, e.ordinality as i from jsonb_array_elements(p_rows) with ordinality e loop
    v_raw := case r.row ->> 'kind'
      when 'percent' then round(v_total * round((r.row ->> 'value')::numeric, 2) / 100, 2)
      when 'amount' then round((r.row ->> 'value')::numeric, 2)
      else 0 end;
    v_amount := case when r.i = v_n then greatest(v_left, 0) else least(greatest(v_raw, 0), greatest(v_left, 0)) end;
    v_left := v_left - v_amount;
    v_out := v_out || jsonb_build_array(r.row || jsonb_build_object('amount', v_amount));
  end loop;
  return v_out;
end $$;

-- What's still to place for a total, exactly (negative: over). Ending with the rest, what the rest
-- comes to.
create function private.schedule_left(p_rows jsonb, p_total numeric) returns numeric
language sql immutable set search_path = '' as $$
  select greatest(round(coalesce(p_total, 0), 2), 0)
         - coalesce(sum(round((e.value ->> 'value')::numeric, 2)) filter (where e.value ->> 'kind' = 'amount'), 0)
         - greatest(round(coalesce(p_total, 0), 2), 0) * coalesce(sum(round((e.value ->> 'value')::numeric, 2)) filter (where e.value ->> 'kind' = 'percent'), 0) / 100
  from jsonb_array_elements(p_rows) e
$$;

/**
 * Why a schedule can't be saved for a total, in the editor's words, or null. It comes to the total
 * exactly (within half a cent of rounding), or, ending with the rest, leaves at least a cent for it.
 */
create function private.schedule_problem(p_rows jsonb, p_total numeric) returns text
language plpgsql immutable set search_path = '' as $$
declare
  v_problem text := private.schedule_shape_problem(p_rows);
  v_left numeric;
begin
  if v_problem is not null or p_rows is null or jsonb_array_length(p_rows) = 0 then
    return v_problem;
  end if;
  v_left := private.schedule_left(p_rows, p_total);
  if p_rows -> -1 ->> 'kind' = 'rest' then
    return case when v_left >= 0.005 then null
      else 'The payments before the last come to the whole total, so nothing is left for the rest.' end;
  end if;
  if abs(v_left) < 0.005 then
    return null;
  end if;
  return case when v_left > 0 then 'The payments come to ' || private.money(round(v_left, 2)) || ' less than the total.'
    else 'The payments come to ' || private.money(round(-v_left, 2)) || ' more than the total.' end;
end $$;

revoke all on function private.schedule_shape_problem(jsonb), private.schedule_amounts(jsonb, numeric), private.schedule_left(jsonb, numeric),
  private.schedule_problem(jsonb, numeric) from public;
grant execute on function private.schedule_amounts(jsonb, numeric), private.schedule_problem(jsonb, numeric) to authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- On the quote: checked as it's saved, the deposit follows it, and it's kept with the approval
-- ---------------------------------------------------------------------------------------------

-- After quote_totals and set_deposit (triggers on a table fire in name order), so the total is the
-- one just worked out and the schedule's deposit has the last word.
create function private.quote_payment_schedule() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_problem text;
  v_first jsonb;
  v_amounts jsonb;
begin
  if jsonb_typeof(new.payment_schedule) = 'array' and jsonb_array_length(new.payment_schedule) = 0 then
    new.payment_schedule := null;
  end if;
  if tg_op = 'INSERT' or new.payment_schedule is distinct from old.payment_schedule then
    if tg_op = 'UPDATE' and old.status in ('approved', 'converted') then
      raise exception 'This quote was approved, so its payment schedule stays as it was signed.' using errcode = '22023';
    end if;
    if new.payment_schedule is not null then
      v_problem := private.schedule_shape_problem(new.payment_schedule);
      if v_problem is not null then
        raise exception '%', v_problem using errcode = '22023';
      end if;
      if new.change_order_for is not null then
        raise exception 'A change order is billed with its job, so it has no payment schedule of its own.' using errcode = '22023';
      end if;
      if new.recurrence_rule is not null then
        raise exception 'Repeating work is billed by the visit or the month, so it has no payment schedule.' using errcode = '22023';
      end if;
      -- A new quote has no lines yet (a copy gets its lines after): its total is checked once it's edited.
      if tg_op = 'UPDATE' then
        v_problem := private.schedule_problem(new.payment_schedule, new.total);
        if v_problem is not null then
          raise exception '%', v_problem using errcode = '22023';
        end if;
      end if;
    end if;
  end if;
  if new.payment_schedule is not null and (new.recurrence_rule is not null or new.change_order_for is not null) then
    raise exception 'A quote with a payment schedule is for one-time work. Take the schedule off first.' using errcode = '22023';
  end if;

  if new.payment_schedule is not null then
    v_amounts := private.schedule_amounts(new.payment_schedule, new.total);
    -- The deposit is the payment due at approval: as a percent when it's one, so it follows the
    -- total as the client picks options; none without one.
    select e.value into v_first from jsonb_array_elements(v_amounts) e where e.value ->> 'due' = 'approval' limit 1;
    if v_first is null then
      new.deposit_amount := 0;
      new.deposit_percent := null;
    else
      new.deposit_amount := (v_first ->> 'amount')::numeric;
      new.deposit_percent := case when v_first ->> 'kind' = 'percent' and jsonb_array_length(v_amounts) > 1 then round((v_first ->> 'value')::numeric, 2) end;
    end if;
    -- Approved (by any path, any server): each payment's amount for the total signed is kept.
    if tg_op = 'UPDATE' and new.status in ('approved', 'converted') and old.status not in ('approved', 'converted') then
      new.approval := coalesce(new.approval, '{}') || jsonb_build_object('payment_schedule', v_amounts);
    end if;
  end if;
  return new;
end $$;
create trigger set_payment_schedule before insert or update on public.quotes
  for each row execute function private.quote_payment_schedule();

-- ---------------------------------------------------------------------------------------------
-- On the job: one row per payment
-- ---------------------------------------------------------------------------------------------

create table public.job_installments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  job_id uuid not null,
  quote_id uuid,
  position integer not null check (position between 1 and 12),
  count integer not null check (count between 1 and 12),
  due text not null check (due in ('approval', 'date', 'work_starts', 'work_done', 'by_hand')),
  due_on date,
  amount numeric(12, 2) not null check (amount >= 0),
  percent numeric(5, 2),
  invoice_id uuid,
  -- When the database made (or tried to make) its invoice by itself: never again after that.
  made_at timestamptz,
  problem text check (length(problem) <= 500),
  -- Sending a made one to the client by itself (settings.payment_schedule.send).
  send_state text check (send_state in ('waiting', 'sending', 'sent', 'failed')),
  send_error text check (length(send_error) <= 500),
  send_claimed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (company_id, id),
  unique (job_id, position),
  check ((due = 'date') = (due_on is not null)),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade,
  foreign key (company_id, quote_id) references public.quotes (company_id, id) on delete set null (quote_id),
  foreign key (company_id, invoice_id) references public.invoices (company_id, id) on delete set null (invoice_id)
);
comment on table public.job_installments is 'A job''s payments from the payment schedule of the quote it came from (quotes.approval.payment_schedule), each with the invoice that bills it. Written by the database alone.';
comment on column public.job_installments.made_at is 'When the database made its invoice by itself (or tried, with problem saying why it couldn''t). It''s never made by itself again; the office can by hand.';
comment on column public.job_installments.send_state is 'Sent to the client by itself (settings.payment_schedule.send): waiting for the server, sending, sent or failed. Null when it isn''t.';
create index job_installments_job_idx on public.job_installments (job_id);
create index job_installments_invoice_idx on public.job_installments (invoice_id) where invoice_id is not null;
create index job_installments_due_idx on public.job_installments (due, due_on) where invoice_id is null and made_at is null;
create index job_installments_send_idx on public.job_installments (send_state) where send_state in ('waiting', 'sending');

-- Read as invoices are, by the people who look after money; only the database writes them.
alter table public.job_installments enable row level security;
create policy job_installments_read on public.job_installments for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}'));
select private.restrict_area('job_installments', 'invoices', true);
revoke insert, update, delete, truncate on public.job_installments from authenticated;
revoke all on public.job_installments from anon;

-- The quote's approved schedule becomes the rows of the first job made from it, once. A deposit
-- invoice made as the client approved, and a final invoice already made, are the payments they bill.
create function private.schedule_to_job(p_quote uuid) returns void
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
         case e.row ->> 'due'
           when 'approval' then coalesce(
             (select i.id from public.invoices i where i.id = q.deposit_invoice_id and i.status <> 'void'),
             (select i.id from public.invoices i where i.job_id = j.id and i.kind = 'deposit' and i.status <> 'void' order by i.created_at limit 1))
           when 'work_done' then (select i.id from public.invoices i where i.job_id = j.id and i.kind = 'standard' and i.status <> 'void' order by i.created_at limit 1)
         end
  from jsonb_array_elements(v_rows) with ordinality e (row, i);
end $$;

create function private.quote_schedule_to_job() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.schedule_to_job(new.id);
  return null;
end $$;
create trigger schedule_to_job after update of status on public.quotes
  for each row when (new.status in ('approved', 'converted') and old.status not in ('approved', 'converted') and new.payment_schedule is not null)
  execute function private.quote_schedule_to_job();

create function private.job_schedule_from_quote() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.schedule_to_job(new.quote_id);
  return null;
end $$;
create trigger schedule_from_quote after insert or update of quote_id on public.jobs
  for each row when (new.quote_id is not null) execute function private.job_schedule_from_quote();

-- A deposit invoice or final invoice made for the job the usual way (the Deposit button, the Client
-- Hub's deposit joining the job, Invoice when the work is done, autopay) is the payment due at
-- approval or when the work is done, unless that one already has an invoice that isn't void.
create function private.invoice_bills_installment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.job_installments s set invoice_id = new.id
   where s.job_id = new.job_id
     and s.due = case new.kind when 'deposit' then 'approval' else 'work_done' end
     and s.invoice_id is distinct from new.id
     and (s.invoice_id is null or exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status = 'void'));
  return null;
end $$;
create trigger bills_installment after insert or update of job_id, status on public.invoices
  for each row when (new.job_id is not null and new.kind in ('deposit', 'standard') and new.status <> 'void')
  execute function private.invoice_bills_installment();

-- ---------------------------------------------------------------------------------------------
-- Making a payment's invoice
-- ---------------------------------------------------------------------------------------------

-- On by settings.payment_schedule.send, off unless set.
create function private.sends_installments(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select c.settings -> 'payment_schedule' -> 'send' from public.companies c where c.id = p_company), 'false'::jsonb) = 'true'::jsonb
$$;

-- "Payment 2 of 3", as the job, the invoice and the notices name it (core schedulePaymentName).
create function private.installment_name(p_position integer, p_count integer) returns text
language sql immutable set search_path = '' as $$
  select 'Payment ' || p_position || ' of ' || p_count
$$;

/**
 * Makes a payment's invoice through create_invoice_for_job (as the function's owner), as a draft.
 * p_by_hand: the office pressed Invoice now, so it's made even when an earlier one was voided or
 * deleted, and a reason it can't be is raised for them. Otherwise (the moment came) it's made only
 * the once: a problem is kept on the row and the office is told, and a made one is either left for
 * the server to send (the company's switch) or the office is told it's ready. Returns the invoice,
 * or null when nothing was made.
 */
create function private.make_installment(p_installment uuid, p_by_hand boolean) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  s public.job_installments;
  j public.jobs;
  v_invoice uuid;
  v_existing bigint;
  v_name text;
  v_total numeric;
  v_number bigint;
  v_bill numeric;
  v_job_total numeric;
  v_job_taxable numeric;
  v_rate numeric;
  v_room numeric;
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
  if s.due = 'work_done' then
    if p_by_hand then
      raise exception '% is the job''s final invoice. Make it with Invoice once the work is done', v_name using errcode = '22023';
    end if;
    return null;
  end if;
  select i.number into v_existing from public.invoices i where i.job_id = j.id and i.kind = 'standard' and i.status <> 'void' order by i.number limit 1;
  if found then
    if p_by_hand then
      raise exception 'This job has its final invoice (#%), which bills what''s left, % included', v_existing, lower(left(v_name, 1)) || substr(v_name, 2) using errcode = '22023';
    end if;
    update public.job_installments set made_at = now(), problem = format('The final invoice (#%s) bills it', v_existing) where id = s.id;
    return null;
  end if;

  -- A payment is part of the quote's total, tax and all. A deposit invoice is never taxed, so it's
  -- the payment itself, as the deposit always was. A progress invoice adds the tax on its taxed share
  -- (create_invoice_for_job), so it bills the payment without its tax: the share the job's taxable
  -- work is of it, at the quote's rate. So the client is asked for the payment, give or take a cent
  -- of rounding that the final invoice evens out. It's never more than is left of the contract after
  -- the deposits and progress invoices before it (a deposit counts its tax against it): what that
  -- leaves is the final invoice's.
  v_bill := s.amount;
  if s.due <> 'approval' then
    select coalesce(sum(round(quantity * unit_price, 2)), 0), coalesce(sum(round(quantity * unit_price, 2)) filter (where taxable), 0)
      into v_job_total, v_job_taxable
    from public.job_line_items where job_id = j.id;
    select coalesce((select q.tax_rate from public.quotes q where q.id = j.quote_id), (c.settings ->> 'default_tax_rate')::numeric, 0)
      into v_rate from public.companies c where c.id = j.company_id;
    v_bill := round(s.amount / (1 + coalesce(v_rate, 0) * case when v_job_total <= 0 or v_job_taxable >= v_job_total then 1 else v_job_taxable / v_job_total end), 2);
    select coalesce((select f.contract_total from public.job_financials f where f.job_id = j.id), 0)
           - coalesce((select sum(i.subtotal) from public.invoices i where i.job_id = j.id and i.kind in ('deposit', 'progress') and i.status <> 'void'), 0)
      into v_room;
    v_bill := least(v_bill, greatest(v_room, 0));
  end if;

  begin
    if v_bill <= 0 then
      raise exception 'Nothing is left to bill on this job before its final invoice' using errcode = '22023';
    end if;
    v_invoice := public.create_invoice_for_job(j.id, case when s.due = 'approval' then 'deposit' else 'progress' end, v_bill);
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

/**
 * Invoice now, from the job: the office makes one payment's invoice early, or again after its
 * invoice was voided. The people who look after money only. Returns the invoice (a draft).
 */
create function public.invoice_installment(p_installment uuid) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_company uuid;
begin
  select company_id into v_company from public.job_installments where id = p_installment;
  if not found or not private.has_role(v_company, '{owner,admin,office}') or not private.has_perm(v_company, 'invoices') then
    raise exception 'Payment not found' using errcode = 'P0002';
  end if;
  return private.make_installment(p_installment, true);
end $$;
revoke execute on function public.invoice_installment(uuid) from public, anon;
grant execute on function public.invoice_installment(uuid) to authenticated, service_role;

-- A job visit going in progress (or finished without that) means the work has started: the payments
-- due then are made. Never stops the crew's tap, as private.visit_finishes_job doesn't: a problem is
-- a warning, and the hourly run tries again.
create function private.work_started(p_job uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  for r in
    select s.id from public.job_installments s
     where s.job_id = p_job and s.due = 'work_starts' and s.invoice_id is null and s.made_at is null
     order by s.position
  loop
    perform private.make_installment(r.id, false);
  end loop;
end $$;

create function private.visit_starts_work() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.job_installments s where s.job_id = new.job_id and s.due = 'work_starts' and s.invoice_id is null and s.made_at is null) then
    begin
      perform private.work_started(new.job_id);
    exception when others then
      raise warning 'a payment due as the work starts: %', sqlerrm;
    end;
  end if;
  return null;
end $$;
create trigger starts_work after insert or update of status on public.visits
  for each row when (new.kind = 'job' and new.job_id is not null and new.status in ('in_progress', 'completed'))
  execute function private.visit_starts_work();

/**
 * Hourly (tasks.ts): the payments whose moment has come and that nobody has made yet: a date that's
 * today or past where the company is, and work that has started (a visit in progress or finished)
 * in case its trigger didn't make it. Only for jobs still going. Also: a send that's been "sending"
 * for half an hour is counted as failed and the office is told (it may have gone, so it isn't sent
 * again). Returns how many invoices it made.
 */
create function public.make_due_installments() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_count integer := 0;
begin
  for r in
    select s.id
      from public.job_installments s
      join public.jobs j on j.id = s.job_id
      join public.companies c on c.id = s.company_id
     where s.invoice_id is null and s.made_at is null and j.status in ('active', 'requires_invoicing')
       and ((s.due = 'date' and s.due_on <= (now() at time zone coalesce(c.timezone, 'UTC'))::date)
            or (s.due = 'work_starts' and exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status in ('in_progress', 'completed'))))
     order by s.job_id, s.position
     for update of s skip locked
  loop
    if private.make_installment(r.id, false) is not null then
      v_count := v_count + 1;
    end if;
  end loop;
  for r in
    select s.id from public.job_installments s
     where s.send_state = 'sending' and s.send_claimed_at < now() - interval '30 minutes'
     for update skip locked
  loop
    perform public.installment_sent(r.id, false, 'It may not have gone out: the server stopped while sending it');
  end loop;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Sending them by themselves (the server's installments task)
-- ---------------------------------------------------------------------------------------------

/** The made payments waiting to be sent, claimed for this run: each is sent once. */
create function public.claim_installment_sends(p_limit integer default 20) returns table (id uuid, company_id uuid, invoice_id uuid)
language sql security definer set search_path = '' as $$
  update public.job_installments s set send_state = 'sending', send_claimed_at = now()
   where s.id in (select x.id from public.job_installments x where x.send_state = 'waiting' and x.invoice_id is not null
                   order by x.made_at limit greatest(coalesce(p_limit, 20), 1) for update skip locked)
  returning s.id, s.company_id, s.invoice_id
$$;

/**
 * How a send went. Not sent: the office is told why, and that it's in Drafts to send by hand.
 */
create function public.installment_sent(p_installment uuid, p_sent boolean, p_error text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  s public.job_installments;
  j public.jobs;
begin
  update public.job_installments
     set send_state = case when p_sent then 'sent' else 'failed' end, send_error = case when p_sent then null else left(p_error, 500) end
   where id = p_installment and send_state = 'sending'
  returning * into s;
  if not found or p_sent then
    return;
  end if;
  select * into j from public.jobs where id = s.job_id;
  insert into public.notifications (company_id, user_id, kind, title, body, link)
  select s.company_id, u, 'invoice', left(format('%s for job #%s wasn''t sent', private.installment_name(s.position, s.count), j.number), 300),
         left(coalesce(nullif(rtrim(btrim(p_error), '.'), ''), 'It couldn''t be sent') || '. It''s in Drafts: send it from the invoice.', 1000),
         '/invoices/' || s.invoice_id
  from private.money_office(s.company_id) u;
end $$;

revoke all on function private.quote_payment_schedule(), private.schedule_to_job(uuid), private.quote_schedule_to_job(), private.job_schedule_from_quote(),
  private.invoice_bills_installment(), private.sends_installments(uuid), private.installment_name(integer, integer), private.make_installment(uuid, boolean),
  private.work_started(uuid), private.visit_starts_work() from public;
revoke execute on function public.make_due_installments(), public.claim_installment_sends(integer), public.installment_sent(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.make_due_installments(), public.claim_installment_sends(integer), public.installment_sent(uuid, boolean, text) to service_role;

-- The new table's policies look up who's asking once per query, as every other table's do.
select private.fold_member_checks('public.job_installments');

-- ---------------------------------------------------------------------------------------------
-- Copies and templates carry it
-- ---------------------------------------------------------------------------------------------

-- As in 20261105000120_template_trip_fee.sql, and the copy has the same payment schedule.
create or replace function public.duplicate_quote(p_quote uuid, p_template_name text default null, p_client uuid default null,
  p_property uuid default null, p_title text default null, p_custom_fields jsonb default null)
returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  q public.quotes;
  o public.quote_options;
  v_template boolean;
  v_new uuid;
  v_id uuid;
  v_map jsonb := '{}';
begin
  select * into q from public.quotes where id = p_quote;
  if not found then
    raise exception 'Quote not found' using errcode = 'P0002';
  end if;
  if p_template_name is not null and p_client is not null then
    raise exception 'A quote template has no client.' using errcode = '22023';
  end if;
  if p_template_name is not null and btrim(p_template_name) = '' then
    raise exception 'Give the template a name.' using errcode = '22023';
  end if;
  v_template := p_template_name is not null or (q.is_template and p_client is null);

  insert into public.quotes (company_id, client_id, property_id, is_template, title, message, discount_amount, tax_rate, deposit_amount, deposit_percent,
                             valid_until, roof_package_id, section_ids, recurrence_rule, active_months, starts_on, ends_on, custom_fields,
                             every_job_items_left_off, payment_schedule)
  select q.company_id,
         case when not v_template then coalesce(p_client, q.client_id) end,
         case when v_template then null when p_client is not null then p_property else q.property_id end,
         v_template,
         left(coalesce(nullif(btrim(p_template_name), ''), nullif(btrim(p_title), ''),
                       case when q.is_template and not v_template then q.title else q.title || ' (copy)' end), 200),
         q.message, q.discount_amount, q.tax_rate, q.deposit_amount, q.deposit_percent,
         case when v_template then null
              when q.is_template then (now() at time zone coalesce(c.timezone, 'UTC'))::date
                                      + coalesce((c.settings ->> 'quote_valid_days')::numeric::integer, 30)
              when q.valid_until > (now() at time zone coalesce(c.timezone, 'UTC'))::date then q.valid_until end,
         q.roof_package_id, q.section_ids, q.recurrence_rule, q.active_months, q.starts_on, q.ends_on,
         case when p_client is not null and p_custom_fields is not null then p_custom_fields
              when v_template or q.is_template then q.custom_fields else '{}' end,
         case when q.is_template then q.every_job_items_left_off else '{}' end,
         q.payment_schedule
    from public.companies c where c.id = q.company_id
  returning id into v_new;

  for o in select * from public.quote_options where quote_id = p_quote order by sort, id loop
    insert into public.quote_options (company_id, quote_id, package_id, name, tier, picture, picture_width, picture_height,
                                      style, highlights, warranty, section_ids, sort)
    values (o.company_id, v_new, o.package_id, o.name, o.tier, o.picture, o.picture_width, o.picture_height,
            o.style, o.highlights, o.warranty, o.section_ids, o.sort)
    returning id into v_id;
    v_map := v_map || jsonb_build_object(o.id::text, v_id);
  end loop;
  if q.option_id is not null then
    update public.quotes set option_id = (v_map ->> q.option_id::text)::uuid
     where id = v_new and option_id is distinct from (v_map ->> q.option_id::text)::uuid;
  end if;

  insert into public.quote_line_items (company_id, quote_id, option_id, service_id, name, description, quantity, unit, unit_price,
                                       unit_cost, taxable, optional, selected, option_group, formula, sort, materials, material_cost)
  select l.company_id, v_new, (v_map ->> l.option_id::text)::uuid, l.service_id, l.name, l.description, l.quantity, l.unit, l.unit_price,
         l.unit_cost, l.taxable, l.optional, not l.optional, l.option_group, l.formula, l.sort, l.materials, l.material_cost
    from public.quote_line_items l where l.quote_id = p_quote
   order by l.sort;
  return v_new;
end $$;

notify pgrst, 'reload schema';
