-- A quote alert doesn't go to the person who did the thing.
--
-- "Tell me about quotes over $X" told the owners, the admins and the quote's salesperson whenever
-- such a quote was sent, approved or sent back for changes, whoever did it. So an owner sending
-- their own quote, or marking it approved, got a bell and a push about what they had just done.
-- Now whoever is signed in and changes the quote is left out; the others are told as before, and so
-- is everyone when the client does it in the Client Hub. The event is still kept once per quote.
--
-- supabase/tests/quote_alerts_test.sql covers it.

-- As in 20261113001120_high_value_quote_alerts.sql, leaving out whoever made the change.
create or replace function private.quote_alert() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_over numeric;
  v_event text;
  v_client text;
  v_title text;
begin
  v_event := case
    when new.status = 'sent' then 'sent'
    when new.status = 'changes_requested' then 'changes_requested'
    -- Converted straight from sent (the office heard yes another way) is approved too.
    when new.status in ('approved', 'converted') and old.status not in ('approved', 'converted') then 'approved'
  end;
  if v_event is null or new.is_template or new.client_id is null then
    return null;
  end if;
  v_over := private.quote_alert_over(new.company_id);
  if v_over is null or new.total < v_over then
    return null;
  end if;
  insert into public.quote_alerts (company_id, quote_id, event, total) values (new.company_id, new.id, v_event, new.total)
  on conflict do nothing;
  if not found then
    return null;
  end if;
  v_client := private.client_name(new.client_id);
  v_title := case v_event
    when 'sent' then format('Quote #%s for %s was sent to %s', new.number, private.money(new.total), v_client)
    when 'approved' then format('%s approved quote #%s for %s', v_client, new.number, private.money(new.total))
    else format('%s asked for changes to quote #%s for %s', v_client, new.number, private.money(new.total)) end;
  insert into public.notifications (company_id, user_id, kind, title, body, link)
  select new.company_id, u.user_id, 'quote', left(v_title, 300),
         left(format('%s. It''s at or above the %s you asked to hear about.', new.title, private.money(v_over)), 1000),
         '/quotes/' || new.id
  from (
    select m.user_id from public.memberships m
     where m.company_id = new.company_id and m.active and m.role in ('owner', 'admin')
    union
    select m.user_id from public.memberships m
     where m.company_id = new.company_id and m.active and m.user_id = new.salesperson_id
  ) u
  -- Not whoever did it: they know. (The client, in the Client Hub, is nobody here.)
  where u.user_id is distinct from (select auth.uid());
  return null;
end $$;

notify pgrst, 'reload schema';
