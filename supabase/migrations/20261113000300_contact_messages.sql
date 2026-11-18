-- A client's other contacts (client_contacts: a spouse, a property manager) each have "Gets emailed
-- reminders and receipts" (notify_email) and "Gets text reminders" (notify_sms), ticked by default,
-- and nothing that sends ever read them: reminders, quotes, invoices and receipts went to the
-- client's own email and phone only. The server now asks one function who a client's message goes
-- to (packages/core/src/recipients.ts clientRecipients), and that reads the ticks.
--
--   companies.settings.contact_messages   { "enabled": bool, "pending": bool, ... }: whether ticked
--                                         contacts get the client's messages. Nothing saved means
--                                         on (a new company). Every company that exists now gets
--                                         off and pending: its contacts were ticked while the ticks
--                                         did nothing, so nobody new is emailed or texted until an
--                                         owner or admin says yes (the Clients page asks once).
--                                         Only set_contact_messages changes it.
--   messages.recipients                   who an email or text went to, when that's known: the
--                                         client, their contacts and addresses typed in.
--   messages.from_phone, from_name        for a text that came in: the number it came from, and
--                                         whose it is when it's a contact's rather than the client's.
--   sms_stops                             the numbers that texted STOP to a company. A client's own
--                                         STOP stays on the client (clients.sms_opt_out_at) as
--                                         before; this also holds a contact's number, which has no
--                                         client row of its own to carry it.
--
-- supabase/tests/contact_messages_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- The company's switch
-- ---------------------------------------------------------------------------------------------

-- Off, and still to be decided, for every company there is now.
update public.companies
   set settings = jsonb_set(coalesce(settings, '{}'), '{contact_messages}', '{"enabled": false, "pending": true}')
 where jsonb_typeof(settings -> 'contact_messages') is distinct from 'object';

-- On while set_contact_messages writes, for the rest of that statement's transaction.
create function private.contact_messages_setting() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(current_setting('jobly.contact_messages', true), '') = 'on'
$$;

-- Someone signed in saving settings keeps settings.contact_messages as it was, as
-- marketing_settings_guard does for Marketing: a page open since before this update, saving the
-- settings it read then, would otherwise take the switch away, which reads as on. The server and
-- migrations have nobody signed in, so they go through.
create function private.contact_messages_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if private.contact_messages_setting() or (select auth.uid()) is null
     or new.settings -> 'contact_messages' is not distinct from old.settings -> 'contact_messages' then
    return new;
  end if;
  new.settings := case when old.settings -> 'contact_messages' is null then coalesce(new.settings, '{}') - 'contact_messages'
    else jsonb_set(coalesce(new.settings, '{}'), '{contact_messages}', old.settings -> 'contact_messages') end;
  return new;
end $$;
create trigger contact_messages_guard before update of settings on public.companies
  for each row execute function private.contact_messages_guard();

-- The switch, for owners and admins (Settings → Client notifications, and the note on the Clients
-- page). Either answer settles it, so the note doesn't come back.
create function public.set_contact_messages(p_company uuid, p_enabled boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if p_enabled is null then
    raise exception 'Say whether contacts get the client''s messages.' using errcode = '22023';
  end if;
  if not private.has_role(p_company, '{owner,admin}') then
    raise exception 'Only owners and admins can change who gets a client''s messages.' using errcode = '42501';
  end if;
  perform set_config('jobly.contact_messages', 'on', true);
  update public.companies
     set settings = jsonb_set(coalesce(settings, '{}'), '{contact_messages}',
       jsonb_build_object('enabled', p_enabled, 'pending', false, 'changed_at', now(), 'changed_by', (select auth.uid())))
   where id = p_company;
  perform set_config('jobly.contact_messages', '', true);
  return p_enabled;
end $$;

revoke all on function private.contact_messages_setting(), private.contact_messages_guard() from public;
revoke execute on function public.set_contact_messages(uuid, boolean) from public, anon;
grant execute on function public.set_contact_messages(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- Who a message went to, and who a text came from
-- ---------------------------------------------------------------------------------------------

alter table public.messages
  add column recipients jsonb check (recipients is null or jsonb_typeof(recipients) = 'array'),
  add column from_phone text check (char_length(from_phone) <= 40),
  add column from_name text check (char_length(from_name) <= 200);
comment on column public.messages.recipients is
  'Who an email or text went to: [{"to": address or number, "name": whose it is, "failed": true when it didn''t reach them}]. Null when it wasn''t recorded (older messages, notes)';
comment on column public.messages.from_phone is 'A text that came in: the number it came from';
comment on column public.messages.from_name is 'A text that came in from a contact''s number rather than the client''s: the contact''s name then';

-- ---------------------------------------------------------------------------------------------
-- Numbers that texted STOP
-- ---------------------------------------------------------------------------------------------

create table public.sms_stops (
  company_id uuid not null references public.companies (id) on delete cascade,
  -- The number's last 10 digits, as the server compares numbers (core phoneMatchKey).
  phone_key text not null check (phone_key ~ '^[0-9]{7,10}$'),
  -- The number as it came.
  phone text not null check (char_length(phone) <= 40),
  stopped_at timestamptz not null default now(),
  primary key (company_id, phone_key)
);
comment on table public.sms_stops is 'Numbers that texted STOP to a company: Jobly doesn''t text them until they text START. The server writes it.';

-- The office reads it (who can't be texted shows where they choose who to send to). Only the
-- server writes it: a STOP is the person's own, and nobody signed in takes it back for them.
alter table public.sms_stops enable row level security;
revoke insert, update, delete on public.sms_stops from authenticated;
create policy sms_stops_read on public.sms_stops for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}'));
select private.fold_member_checks('public.sms_stops');

-- The clients who have texts off today: their numbers are stopped for their company too, so a
-- contact kept under the same number isn't texted either.
insert into public.sms_stops (company_id, phone_key, phone, stopped_at)
select distinct on (c.company_id, k.key) c.company_id, k.key, left(c.phone, 40), c.sms_opt_out_at
  from public.clients c
  cross join lateral (select right(regexp_replace(c.phone, '\D', '', 'g'), 10) as key) k
 where c.sms_opt_out_at is not null and c.phone is not null and k.key ~ '^[0-9]{7,10}$'
 order by c.company_id, k.key, c.sms_opt_out_at
on conflict do nothing;

notify pgrst, 'reload schema';
