-- "Draft a quote" on a request: the server fills a draft quote from the request (services/quoteDrafts.ts),
-- with Claude when the company has switched it on for this, else from its price list by name. The
-- office reviews the draft; nothing is sent.
--
--   quotes.drafted           how the draft was made, for the office's eyes only (never sent to the
--                            Client Hub): {by: claude|price_list, at, request_number, check: [line
--                            ids whose quantity to check], notes: the request's answers, note}
--   settings.quote_ai        {on, checked_at, checked_by}: Claude drafts them. Only the server
--                            writes it (quote_ai_settings_guard), after checking the key with
--                            Claude, so a page saving the company's other settings can't turn it on.
--   settings.quotes.draft_requests
--                            a request that comes in from a booking form or the Client Hub gets a
--                            draft by itself, and the office is told. Off unless set.

alter table public.quotes add column drafted jsonb;
comment on column public.quotes.drafted is 'How "Draft a quote" filled it in (services/quoteDrafts.ts): {by, at, request_number, check, notes, note}. The office''s alone: never sent to clients.';

-- Someone signed in saving settings keeps settings.quote_ai as it was, as social_settings_guard does:
-- only the server (nobody signed in) changes it.
create function private.quote_ai_settings_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null
     or new.settings -> 'quote_ai' is not distinct from old.settings -> 'quote_ai' then
    return new;
  end if;
  new.settings := case when old.settings -> 'quote_ai' is null then coalesce(new.settings, '{}') - 'quote_ai'
    else jsonb_set(coalesce(new.settings, '{}'), '{quote_ai}', old.settings -> 'quote_ai') end;
  return new;
end $$;
create trigger quote_ai_settings_guard before update of settings on public.companies
  for each row execute function private.quote_ai_settings_guard();

-- The server, once Claude answered with the company's key (or the switch is turned off): writes
-- settings.quote_ai alone, so a change saved meanwhile isn't undone.
create function public.set_quote_ai(p_company uuid, p_on boolean, p_by uuid) returns jsonb
language sql security definer set search_path = '' as $$
  update public.companies c
     set settings = jsonb_set(coalesce(c.settings, '{}'), '{quote_ai}', jsonb_build_object('on', coalesce(p_on, false), 'checked_at', now(), 'checked_by', p_by))
   where c.id = p_company
  returning c.settings -> 'quote_ai'
$$;

revoke all on function private.quote_ai_settings_guard() from public;
revoke execute on function public.set_quote_ai(uuid, boolean, uuid) from public, anon, authenticated;
grant execute on function public.set_quote_ai(uuid, boolean, uuid) to service_role;

notify pgrst, 'reload schema';
