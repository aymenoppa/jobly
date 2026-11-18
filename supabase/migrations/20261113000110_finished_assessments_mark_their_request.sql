-- A request whose assessment visit is finished reads Assessment done.
--
-- The request stayed at Assessment booked (or New, when the visit wasn't booked from the request's
-- page) until someone opened it and pressed Mark assessment done, so Home's "Assessment done" count
-- and the Requests list didn't show whose quote was waiting to be written. Now finishing a request's
-- assessment visit makes the change that button makes, once no other assessment for the request is
-- still open. Nothing is sent to anyone: the status is all that changes, and a request already
-- quoted, converted or archived stays as it is.
--
-- supabase/tests/finished_assessments_test.sql covers it.

-- A problem here must never stop the tap that finished the visit (private.visit_finishes_job).
create function private.visit_finishes_assessment() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    -- Finished now, or logged as already completed by someone signed in (not loaded by the server).
    if new.kind = 'assessment' and new.request_id is not null and new.status = 'completed'
       and ((tg_op = 'UPDATE' and old.status is distinct from 'completed') or (tg_op = 'INSERT' and (select auth.uid()) is not null)) then
      update public.requests r set status = 'assessment_complete'
      where r.id = new.request_id and r.status in ('new', 'assessment_scheduled')
        and not exists (select 1 from public.visits v
                        where v.request_id = r.id and v.kind = 'assessment' and v.id <> new.id and v.status not in ('completed', 'cancelled'));
    end if;
  exception when others then
    raise warning 'finishing an assessment: %', sqlerrm;
  end;
  return null;
end $$;
revoke all on function private.visit_finishes_assessment() from public;
create trigger finishes_assessment after insert or update on public.visits
  for each row execute function private.visit_finishes_assessment();
