-- A one-off job whose last visit is finished asks to be invoiced by itself.
--
-- Until now nothing happened to the job when its last visit was completed: it read Unscheduled, and
-- only reached Requires invoicing (Home, the Jobs list, Invoices → Ready to invoice, batch invoicing,
-- the job.completed event and autopay's charge) when someone opened it and pressed Mark work
-- complete. That is how invoices got missed.
--
-- Now, when a job visit is completed, cancelled or deleted and its one-off, active job has no job
-- visit left open and at least one completed, the database makes the change the button makes
-- (status = 'requires_invoicing'), so everything that follows from the button follows from this,
-- and tells the people who look after money on the bell, once for the job. Whenever the change
-- reaches the database: a Complete tapped offline counts when it syncs, and so does a visit someone
-- logs as already completed.
--
--   Already invoiced   A job with nothing left to invoice (its final invoice is made, or every
--                      finished visit of a job billed per visit is on one) is closed instead:
--                      Requires invoicing would ask for an invoice it already has.
--   Autopay            A job whose card that change would charge (private.autopay_queue) is left
--                      as it is: a crew's tap doesn't charge a card. The office is told, and that
--                      pressing Mark work complete charges it.
--   The switch         companies.settings.jobs.complete_when_visits_done, on unless it's false
--                      (Settings → Company; core completesWhenVisitsDone). Off, the job stays as
--                      it is and the office is still told.
--
-- jobs.finished_by_visits_at says the database made the change, which the job's page says under its
-- status. While such a job still waits for its invoice, a visit added to it or reopened on it puts it
-- back to active (there's work left after all), and its last visit finishing marks it again.
--
-- Jobs already sitting finished aren't marked by this migration: doing so would raise job.completed
-- for every one of them at once, and the rules that follow it write to clients.
--
-- supabase/tests/finished_jobs_test.sql covers it.

alter table public.jobs add column finished_by_visits_at timestamptz;
comment on column public.jobs.finished_by_visits_at is 'When the database marked a one-off job''s work complete (or closed it) because its last visit was finished; null when a person did, and once the job is active again. Set by the database.';

-- Only the database says so, and a job that's active again has nothing marked.
create function private.job_finished_mark() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.status = 'active' then
    new.finished_by_visits_at := null;
  elsif new.finished_by_visits_at is distinct from old.finished_by_visits_at
        and coalesce(current_setting('jobly.job_finished', true), '') <> 'on' then
    new.finished_by_visits_at := old.finished_by_visits_at;
  end if;
  return new;
end $$;
revoke all on function private.job_finished_mark() from public;
create trigger finished_mark before insert or update on public.jobs
  for each row execute function private.job_finished_mark();

-- The company's switch: on unless it's been turned off.
create function private.completes_finished_jobs(p_company uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select c.settings -> 'jobs' -> 'complete_when_visits_done' from public.companies c where c.id = p_company), 'true'::jsonb)
         is distinct from 'false'::jsonb
$$;

-- A notification about a job for the people who look after money (kind 'job', as an automation's).
create function private.job_notify(p_company uuid, p_job uuid, p_title text, p_body text) returns void
language sql security definer set search_path = '' as $$
  insert into public.notifications (company_id, user_id, kind, title, body, link)
  select p_company, u, 'job', left(p_title, 300), p_body, '/jobs/' || p_job
  from private.money_office(p_company) u
$$;

/**
 * A job visit of p_job was just finished, cancelled or deleted: if that leaves a one-off, active job
 * with no job visit open and at least one completed, its work is done. See the top of this file for
 * what happens then.
 */
create function private.job_visits_finished(p_job uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  j public.jobs;
  v_name text;
  v_card uuid;
  v_to_invoice boolean;
begin
  -- Most visits finished are a recurring job's: those are left without a lock on the job.
  if not exists (select 1 from public.jobs x where x.id = p_job and x.kind = 'one_off' and x.status = 'active') then
    return;
  end if;
  -- Two crews finishing a job's last two visits at the same moment each see the other's still open.
  -- The job is locked first, so the second waits here and then sees the first's.
  select * into j from public.jobs where id = p_job for no key update;
  if not found or j.kind <> 'one_off' or j.status <> 'active' then
    return;
  end if;
  if exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status not in ('completed', 'cancelled'))
     or not exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status = 'completed') then
    return;
  end if;

  v_name := format('Job #%s for %s', j.number, private.client_name(j.client_id));
  -- What's left to invoice: a per-visit job's finished visits not on an invoice, any other job's
  -- final invoice (create_invoice_for_job makes one, and refuses a second).
  v_to_invoice := case when j.billing_mode = 'per_visit'
    then exists (select 1 from public.visits v where v.job_id = j.id and v.kind = 'job' and v.status = 'completed' and v.invoice_id is null)
    else not exists (select 1 from public.invoices i where i.job_id = j.id and i.kind = 'standard' and i.status <> 'void') end;
  -- The card marking the work complete would charge: the same test as private.autopay_queue's.
  v_card := case when j.autopay and j.billing_mode = 'on_completion' then private.autopay_ready(j.company_id, j.client_id) end;

  if not v_to_invoice then
    if private.completes_finished_jobs(j.company_id) then
      perform set_config('jobly.job_finished', 'on', true);
      update public.jobs set status = 'completed', finished_by_visits_at = now() where id = j.id;
      perform set_config('jobly.job_finished', 'off', true);
    end if;
  elsif v_card is not null then
    perform private.job_notify(j.company_id, j.id, v_name || ' is finished. Mark work complete to charge their card',
      format('It''s on autopay, so it wasn''t marked complete for you. Pressing Mark work complete on the job charges %s.',
             coalesce(private.method_label_of(v_card), 'their saved card')));
  elsif not private.completes_finished_jobs(j.company_id) then
    perform private.job_notify(j.company_id, j.id, v_name || ' has had its last visit finished',
      'Press Mark work complete on the job when it''s ready to invoice.');
  else
    perform set_config('jobly.job_finished', 'on', true);
    update public.jobs set status = 'requires_invoicing', finished_by_visits_at = now() where id = j.id;
    perform set_config('jobly.job_finished', 'off', true);
    perform private.job_notify(j.company_id, j.id, v_name || ' is finished and ready to invoice',
      'Its last visit was finished, so the work was marked complete.');
  end if;
end $$;

-- A job visit added to, or reopened on, a job the database marked complete that still waits for its
-- invoice: there's work left, so it's active again (and marked again when that visit is finished).
-- A job a person marked, or one already invoiced or closed, stays as they left it.
create function private.job_visit_reopened(p_job uuid) returns void
language sql security definer set search_path = '' as $$
  update public.jobs set status = 'active'
  where id = p_job and kind = 'one_off' and status = 'requires_invoicing' and finished_by_visits_at is not null
$$;

-- A problem here must never stop the crew's tap (an offline tap syncs later and would fail then), so
-- it's noted as a warning and the visit goes on as it was saved, as with private.autopay_visit.
create function private.visit_finishes_job() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    if tg_op = 'DELETE' then
      -- A job deleted takes its visits with it: by then it isn't there to mark.
      if old.kind = 'job' and old.job_id is not null and old.status not in ('completed', 'cancelled') then
        perform private.job_visits_finished(old.job_id);
      end if;
    elsif new.kind = 'job' and new.job_id is not null then
      if new.status in ('completed', 'cancelled') then
        -- A visit someone logs as already completed counts too (the visit's dialog lets the office).
        -- Not one the server or an import adds with nobody signed in: that's history being loaded.
        if (tg_op = 'UPDATE' and new.status is distinct from old.status)
           or (tg_op = 'INSERT' and new.status = 'completed' and (select auth.uid()) is not null) then
          perform private.job_visits_finished(new.job_id);
        end if;
      elsif tg_op = 'INSERT' or old.status in ('completed', 'cancelled') or old.kind <> 'job' or old.job_id is distinct from new.job_id then
        perform private.job_visit_reopened(new.job_id);
      end if;
    end if;
  exception when others then
    raise warning 'finishing a job: %', sqlerrm;
  end;
  return null;
end $$;
create trigger finishes_job after insert or update or delete on public.visits
  for each row execute function private.visit_finishes_job();

revoke all on function private.completes_finished_jobs(uuid), private.job_notify(uuid, uuid, text, text), private.job_visits_finished(uuid),
  private.job_visit_reopened(uuid), private.visit_finishes_job() from public;

notify pgrst, 'reload schema';
