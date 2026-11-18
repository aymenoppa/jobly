-- A scheduled payment made because a visit was started waits half an hour before it's sent by itself.
--
-- With "Send scheduled payments to clients by themselves" on, a crew's Start tap made the payment
-- due as the work starts and the server emailed it to the client within five minutes. A tap on the
-- wrong visit sent an invoice, and putting the visit back did nothing. The server also sent whatever
-- it had claimed, so an invoice the office had already sent by hand went out a second time.
--
--   Waiting         claim_installment_sends leaves a payment due as the work starts alone until
--                   30 minutes after it was made. Dated payments go as before.
--   Called off      A started visit that goes back (to scheduled, say) while its job has no other
--                   visit started, and the payment is still waiting: a draft nobody has touched is
--                   deleted and the payment is as it was before the tap, to be made when the work
--                   really starts. One somebody has changed is theirs: it stays in Drafts, isn't
--                   sent by itself, and the office is told.
--   Sent by hand    Only a draft is ever claimed. A waiting payment whose invoice is no longer a
--                   draft (sent by hand, paid, voided) is simply no longer waiting, and the server
--                   checks once more just before it sends (installment_send_called_off).
--
-- supabase/tests/payment_schedule_test.sql covers it.

-- How long a payment made as the work starts waits before the server sends it.
create function private.started_payment_wait() returns interval
language sql immutable set search_path = '' as $$ select interval '30 minutes' $$;

/** As in 20261113001100_payment_schedules.sql: the made payments waiting to be sent, claimed for this run, each sent once. Now only drafts, and one made as the work starts only once it has waited. */
create or replace function public.claim_installment_sends(p_limit integer default 20) returns table (id uuid, company_id uuid, invoice_id uuid)
language plpgsql security definer set search_path = '' as $$
begin
  -- No longer a draft (the office sent it, or voided it), or gone: there's nothing to send.
  update public.job_installments s set send_state = null, send_claimed_at = null
   where s.send_state = 'waiting'
     and not exists (select 1 from public.invoices i where i.id = s.invoice_id and i.status = 'draft');
  return query
  update public.job_installments s set send_state = 'sending', send_claimed_at = now()
   where s.id in (select x.id from public.job_installments x
                   where x.send_state = 'waiting' and x.invoice_id is not null
                     and (x.due <> 'work_starts' or x.made_at <= now() - private.started_payment_wait())
                   order by x.made_at limit greatest(coalesce(p_limit, 20), 1) for update skip locked)
  returning s.id, s.company_id, s.invoice_id;
end $$;

/** The server found a claimed payment's invoice already sent, or gone, just before sending it: it isn't sent, and nobody needs telling. */
create function public.installment_send_called_off(p_installment uuid) returns void
language sql security definer set search_path = '' as $$
  update public.job_installments set send_state = null, send_claimed_at = null where id = p_installment and send_state = 'sending'
$$;

/**
 * A job visit that had been started isn't any more, and no other visit of its job is: the work
 * hasn't started after all. A payment made for it that's still waiting to be sent is called off (see
 * the top of this file). Never stops the change to the visit.
 */
create function private.visit_unstarts_work() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  if exists (select 1 from public.visits v where v.job_id = new.job_id and v.kind = 'job' and v.id <> new.id and v.status in ('in_progress', 'completed')) then
    return null;
  end if;
  for r in
    select s.id, s.position, s.count, s.invoice_id, j.company_id, j.id as job_id, j.number,
           (i.status = 'draft' and i.updated_at = i.created_at) as untouched
      from public.job_installments s
      join public.jobs j on j.id = s.job_id
      join public.invoices i on i.id = s.invoice_id
     where s.job_id = new.job_id and s.due = 'work_starts' and s.send_state = 'waiting'
     for update of s
  loop
    begin
      if r.untouched then
        delete from public.invoices where id = r.invoice_id;
        update public.job_installments set invoice_id = null, made_at = null, send_state = null, problem = null where id = r.id;
      else
        update public.job_installments set send_state = null where id = r.id;
        perform private.job_notify(r.company_id, r.job_id,
          format('%s for job #%s wasn''t sent', private.installment_name(r.position, r.count), r.number),
          'The visit that started the work was put back, and its invoice had been changed, so it''s in Drafts for you to send or delete.');
      end if;
    exception when others then
      raise warning 'calling off a payment: %', sqlerrm;
      update public.job_installments set send_state = null where id = r.id;
    end;
  end loop;
  return null;
end $$;
create trigger unstarts_work after update of status on public.visits
  for each row when (new.kind = 'job' and new.job_id is not null and old.status in ('in_progress', 'completed') and new.status not in ('in_progress', 'completed'))
  execute function private.visit_unstarts_work();

revoke all on function private.started_payment_wait(), private.visit_unstarts_work() from public;
revoke execute on function public.claim_installment_sends(integer), public.installment_send_called_off(uuid) from public, anon, authenticated;
grant execute on function public.claim_installment_sends(integer), public.installment_send_called_off(uuid) to service_role;

notify pgrst, 'reload schema';
