-- One scheduled payment that can't be made doesn't stop the hourly run for the others.
--
-- make_due_installments made every due payment in one go, and private.make_installment only kept
-- the reasons it expects (more than what's left to bill, and the like). Anything else on one payment
-- (a guard on invoices it didn't foresee, say) undid the whole run, every hour: no dated payment
-- after it was made for any job, and the sends left "sending" were never looked at.
--
-- Now each payment is made on its own. One that fails some other way keeps its reason (problem) and
-- is tried again on the next two runs, in case it was a passing thing; after the third it's left
-- for the office (made_at, as with any payment that couldn't be made), who are told once, with the
-- reason, and can invoice it from the job. The others, and the look at stuck sends, go on.
--
-- job_installments.attempts counts those tries. supabase/tests/payment_schedule_test.sql covers it.

alter table public.job_installments add column attempts integer not null default 0;
comment on column public.job_installments.attempts is 'How many hourly runs failed to make its invoice for a reason the database didn''t expect. After three it''s left for the office (made_at).';

-- As in 20261113001100_payment_schedules.sql, each payment on its own: see the top of this file.
create or replace function public.make_due_installments() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_count integer := 0;
  v_reason text;
  v_attempts integer;
begin
  for r in
    select s.id, s.position, s.count, j.id as job_id, j.number, j.company_id
      from public.job_installments s
      join public.jobs j on j.id = s.job_id
      join public.companies c on c.id = s.company_id
     where s.invoice_id is null and s.made_at is null and j.status in ('active', 'requires_invoicing')
       and ((s.due = 'date' and s.due_on <= (now() at time zone coalesce(c.timezone, 'UTC'))::date)
            or (s.due = 'work_starts' and exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status in ('in_progress', 'completed'))))
     order by s.job_id, s.position
     for update of s skip locked
  loop
    begin
      if private.make_installment(r.id, false) is not null then
        v_count := v_count + 1;
      end if;
    exception when others then
      v_reason := sqlerrm;
      update public.job_installments set attempts = attempts + 1, problem = left(v_reason, 500) where id = r.id returning attempts into v_attempts;
      if v_attempts >= 3 then
        update public.job_installments set made_at = now() where id = r.id;
        perform private.job_notify(r.company_id, r.job_id,
          format('%s for job #%s couldn''t be invoiced', private.installment_name(r.position, r.count), r.number),
          left(rtrim(v_reason, '.'), 300) || '. It was tried three times and won''t be tried again by itself. Invoice it from the job when it''s sorted out.');
      end if;
      raise warning 'payment % of job #%: %', r.position, r.number, v_reason;
    end;
  end loop;
  for r in
    select s.id from public.job_installments s
     where s.send_state = 'sending' and s.send_claimed_at < now() - interval '30 minutes'
     for update skip locked
  loop
    begin
      perform public.installment_sent(r.id, false, 'It may not have gone out: the server stopped while sending it');
    exception when others then
      raise warning 'a stuck send: %', sqlerrm;
    end;
  end loop;
  return v_count;
end $$;
revoke execute on function public.make_due_installments() from public, anon, authenticated;
grant execute on function public.make_due_installments() to service_role;

notify pgrst, 'reload schema';
