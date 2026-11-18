-- "Tell me about quotes over $X": when a quote at or above the amount is sent, approved, or the
-- client asks for changes, the owners, the admins and the quote's salesperson (quotes.salesperson_id)
-- are told on the bell and by push (kind 'quote', the "Other alerts" topic, which pushes by default),
-- with the client, the amount and what happened. Once per quote per event, whatever path changed the
-- status (the office, the Client Hub, an assistant, any server): quote_alerts keeps which were told.
--
--   settings.quotes.alert_over   the amount; off while it isn't a number above 0 (so off for every
--                                company until someone sets it, in Settings → Company)
--
-- Requests aren't quotes, and a quote template is never sent, so neither is ever told about.
-- supabase/tests/quote_alerts_test.sql covers it.

create table public.quote_alerts (
  company_id uuid not null,
  quote_id uuid not null,
  event text not null check (event in ('sent', 'approved', 'changes_requested')),
  total numeric(12, 2) not null,
  created_at timestamptz not null default now(),
  primary key (quote_id, event),
  foreign key (company_id, quote_id) references public.quotes (company_id, id) on delete cascade
);
comment on table public.quote_alerts is 'Which events of a quote at or above settings.quotes.alert_over the office was told about, so each is told once. Written by the database alone.';
alter table public.quote_alerts enable row level security;
create policy quote_alerts_read on public.quote_alerts for select to authenticated
  using (private.has_role(company_id, '{owner,admin}'));
revoke insert, update, delete, truncate on public.quote_alerts from authenticated;
revoke all on public.quote_alerts from anon;

-- The amount, or null while it's off.
create function private.quote_alert_over(p_company uuid) returns numeric
language sql stable security definer set search_path = '' as $$
  select case when jsonb_typeof(c.settings -> 'quotes' -> 'alert_over') = 'number' and (c.settings -> 'quotes' ->> 'alert_over')::numeric > 0
              then (c.settings -> 'quotes' ->> 'alert_over')::numeric end
  from public.companies c where c.id = p_company
$$;

create function private.quote_alert() returns trigger
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
  ) u;
  return null;
end $$;
create trigger high_value_alert after update of status on public.quotes
  for each row when (new.status is distinct from old.status and new.status in ('sent', 'changes_requested', 'approved', 'converted'))
  execute function private.quote_alert();

revoke all on function private.quote_alert_over(uuid), private.quote_alert() from public;

-- The new table's policy looks up who's asking once per query, as every other table's do.
select private.fold_member_checks('public.quote_alerts');

notify pgrst, 'reload schema';
