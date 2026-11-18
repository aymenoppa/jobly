-- A quote drafted by itself as a request came in leaves the request alone until the quote is sent.
--
-- "Draft a quote when a request comes in" made its draft the way Create quote does, which marks the
-- request Quoted. So within a second of arriving every request left the New and Open tabs, the
-- menu's count and Home's, could no longer be booked at the time its client asked for (that needs a
-- new request), and one whose form had booked its assessment at once lost that status too.
--
-- The server now leaves the request as it is for a draft made by itself (quotes.drafted.auto), and
-- makes no quote when the price list had nothing for it. This is the other half: nobody has quoted
-- the client anything while that draft sits, so the request becomes Quoted when the draft stops
-- being one (it's sent, or approved), as it would have when someone pressed Create quote. A request
-- already converted or archived stays as it is.
--
-- supabase/tests/quote_drafts_test.sql covers it.

create function private.auto_draft_quotes_request() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.requests r set status = 'quoted'
   where r.id = new.request_id and r.company_id = new.company_id
     and r.status in ('new', 'assessment_scheduled', 'assessment_complete');
  return null;
end $$;
revoke all on function private.auto_draft_quotes_request() from public;
create trigger auto_draft_quotes_request after update of status on public.quotes
  for each row when (old.status = 'draft' and new.status in ('sent', 'changes_requested', 'approved', 'converted')
                     and new.request_id is not null and new.drafted -> 'auto' = 'true'::jsonb)
  execute function private.auto_draft_quotes_request();
