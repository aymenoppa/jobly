-- A job with scheduled payments still to come isn't switched to invoicing visit by visit silently.
--
-- A one-off job made from a quote with a payment schedule could be changed to invoicing after each
-- visit, or to a repeating job (the job's details, an AI assistant, the API), and kept its schedule.
-- Visit invoices bill the job's lines in full each time and take nothing off, so every payment the
-- schedule went on to make (a date coming round, the work starting) billed the same work again.
--
--   The guard      Changing a job to repeating, or to billing after each visit or by the month,
--                  while it has payments without an invoice is refused, naming them. Whoever is
--                  changing it has to choose.
--   Dropping them  drop_unmade_installments(job) takes the payments without an invoice off the
--                  job, for the people who look after invoices; the job's details ask first, naming
--                  each, then save. Payments already invoiced keep their invoices and stay listed.
--   No way round   private.make_installment makes nothing for a job billed that way, whoever asks.
--
-- Jobs already switched: their payments still to come are marked as not made by themselves, with
-- why, so nothing more is billed on top of their visit invoices. The office sees them on the job.
--
-- supabase/tests/payment_schedule_test.sql covers it.

-- "Payment 2 of 3 ($330.00), Payment 3 of 3 ($440.00)": a job's payments without an invoice.
create function private.unmade_installments_text(p_job uuid) returns text
language sql stable security definer set search_path = '' as $$
  select string_agg(private.installment_name(s.position, s.count) || ' (' || private.money(s.amount) || ')', ', ' order by s.position)
  from private.unbilled_installments(p_job) s
$$;

create function private.job_billing_keeps_schedule() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_unmade text;
begin
  if (new.kind = 'recurring' or new.billing_mode in ('per_visit', 'fixed_schedule'))
     and (old.kind is distinct from new.kind or old.billing_mode is distinct from new.billing_mode) then
    v_unmade := private.unmade_installments_text(new.id);
    if v_unmade is not null then
      raise exception 'This job''s payment schedule still has payments to come: %. Billing it % would bill them twice, so drop them from the job first',
        v_unmade, case when new.kind = 'recurring' then 'as repeating work' else 'after each visit' end using errcode = '22023';
    end if;
  end if;
  return new;
end $$;
-- After align_billing (triggers on a table fire in name order), which works out billing_mode.
create trigger keeps_schedule before update of kind, billing_mode, pricing, invoice_schedule on public.jobs
  for each row execute function private.job_billing_keeps_schedule();

/**
 * Takes a job's payments that have no invoice (or only a void one) off it, so it can be billed visit
 * by visit. For the people who look after invoices. Returns how many were dropped.
 */
create function public.drop_unmade_installments(p_job uuid) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_company uuid;
  v_count integer;
begin
  select company_id into v_company from public.jobs where id = p_job;
  if not found or not private.has_role(v_company, '{owner,admin,office}') or not private.has_perm(v_company, 'invoices') then
    raise exception 'Job not found' using errcode = 'P0002';
  end if;
  with gone as (
    delete from public.job_installments s
     where s.job_id = p_job and not exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status <> 'void')
    returning 1
  )
  select count(*) into v_count from gone;
  return v_count;
end $$;
revoke all on function private.unmade_installments_text(uuid), private.job_billing_keeps_schedule() from public;
revoke execute on function public.drop_unmade_installments(uuid) from public, anon;
grant execute on function public.drop_unmade_installments(uuid) to authenticated, service_role;

/**
 * Makes a payment's invoice through create_invoice_for_job (as the function's owner), as a draft:
 * the job's final invoice when it's the last payment without one, an invoice on account for its
 * amount otherwise (see the top of this file). p_by_hand: the office pressed Invoice now, so it's
 * made even when an earlier one was voided or deleted, and a reason it can't be is raised for them.
 * Otherwise (the moment came) it's made only the once: a problem is kept on the row and the office
 * is told, and a made one is either left for the server to send (the company's switch) or the office
 * is told it's ready. Returns the invoice, or null when nothing was made.
 * As in 20261113001600_scheduled_payments_bill_what_was_signed.sql, and never for a job that's
 * invoiced visit by visit or as repeating work.
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
  -- A job invoiced visit by visit, or by the month, bills its work that way: a payment of the old
  -- schedule on top would bill it twice. (private.job_billing_keeps_schedule doesn't let a job get
  -- here with payments to come; this is for one that did before it.)
  if j.kind = 'recurring' or j.billing_mode in ('per_visit', 'fixed_schedule') then
    if p_by_hand then
      raise exception 'This job is invoiced %, so its payment schedule no longer applies', case when j.billing_mode = 'per_visit' then 'after each visit' else 'as repeating work' end
        using errcode = '22023';
    end if;
    update public.job_installments set made_at = now(), problem = 'Not made: this job is invoiced visit by visit now' where id = s.id;
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

-- Jobs switched before this: what their schedule hasn't made yet isn't made by itself.
update public.job_installments s
   set made_at = coalesce(s.made_at, now()), problem = 'Not made: this job is invoiced visit by visit now'
  from public.jobs j
 where j.id = s.job_id and (j.kind = 'recurring' or j.billing_mode in ('per_visit', 'fixed_schedule'))
   and not exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status <> 'void');

notify pgrst, 'reload schema';
