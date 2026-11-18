-- Where a number that gets texts came from, and when. Twilio's messaging policy asks a sender to
-- keep "proof of all consents obtained from recipients" with "the date and the method through
-- which that consent was obtained", and nothing recorded either: a phone number was a phone
-- number, whoever typed it. Now each client and contact carries where their number came from.
--
--   clients.sms_consent_at, sms_consent_source
--   client_contacts.sms_consent_at, sms_consent_source
--       'booking_form'   they typed it on the business's booking form, under the line that says
--                        the business will text them about the booking
--       'referral_form'  the same, on a referral page
--       'website_form'   on a form on the business's own website
--       'hub'            in their own Client Hub
--       'office'         someone in the office entered the number (a client), or ticked "Gets
--                        text reminders" (a contact), which the form says to do only if they agreed
--     Null: a number from before this was kept, or one nothing is known about.
--
-- The database stamps 'office' itself when someone signed in adds or changes a number, so every
-- screen, import and assistant is covered and nobody signed in can write a record that says
-- otherwise. The server says where a number came from when a public form brought it.
--
-- New contacts are also no longer ticked for texts unless whoever adds them says so: the default
-- for client_contacts.notify_sms is now false. Contacts that exist keep their ticks.
--
-- supabase/tests/text_consent_test.sql covers it.

alter table public.clients
  add column sms_consent_at timestamptz,
  add column sms_consent_source text check (sms_consent_source in ('booking_form', 'referral_form', 'website_form', 'hub', 'office'));
alter table public.client_contacts
  add column sms_consent_at timestamptz,
  add column sms_consent_source text check (sms_consent_source in ('booking_form', 'referral_form', 'website_form', 'hub', 'office'));
comment on column public.clients.sms_consent_at is 'When the client''s phone number was given or entered, for the record of their consent to texts';
comment on column public.clients.sms_consent_source is 'Where the client''s phone number came from: booking_form, referral_form, website_form, hub, or office (entered by someone in the office)';
comment on column public.client_contacts.sms_consent_at is 'When the contact was ticked to get texts, or gave their number';
comment on column public.client_contacts.sms_consent_source is 'Where the contact''s say-so to be texted came from: office (ticked by someone in the office), or the form they gave the number on';

alter table public.client_contacts alter column notify_sms set default false;

-- A number for comparing, as the server compares them (core phoneMatchKey): its last 10 digits.
create function private.phone_match_key(p_phone text) returns text
language sql immutable set search_path = '' as $$
  select right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10)
$$;

-- A client's number: where it came from follows the number. Someone signed in adding or changing
-- it is the office entering it, now; they can't say otherwise, and an edit to anything else leaves
-- the record alone. The server (a public form) says where it came from itself; a number it
-- changes without saying loses the old number's record.
create function private.client_sms_consent() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new_number boolean := new.phone is not null and btrim(new.phone) <> ''
    and (tg_op = 'INSERT' or private.phone_match_key(new.phone) is distinct from private.phone_match_key(old.phone));
  v_said boolean := tg_op = 'INSERT' and new.sms_consent_source is not null
    or tg_op = 'UPDATE' and (new.sms_consent_source is distinct from old.sms_consent_source or new.sms_consent_at is distinct from old.sms_consent_at);
begin
  if new.phone is null or btrim(new.phone) = '' then
    new.sms_consent_at := null;
    new.sms_consent_source := null;
  elsif (select auth.role()) = 'authenticated' then
    if v_new_number then
      new.sms_consent_at := now();
      new.sms_consent_source := 'office';
    elsif tg_op = 'UPDATE' then
      new.sms_consent_at := old.sms_consent_at;
      new.sms_consent_source := old.sms_consent_source;
    end if;
  elsif v_new_number and not v_said then
    new.sms_consent_at := null;
    new.sms_consent_source := null;
  end if;
  return new;
end $$;
create trigger client_sms_consent before insert or update of phone, sms_consent_at, sms_consent_source on public.clients
  for each row execute function private.client_sms_consent();

-- A contact's: recorded when someone signed in ticks them for texts, or changes the number of one
-- who is ticked. Unticked, or with no number, there's nothing to record.
create function private.contact_sms_consent() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_texted boolean := new.notify_sms and new.phone is not null and btrim(new.phone) <> '';
  v_newly boolean := tg_op = 'INSERT' or not old.notify_sms or old.phone is null
    or private.phone_match_key(new.phone) is distinct from private.phone_match_key(old.phone);
begin
  if not v_texted then
    new.sms_consent_at := null;
    new.sms_consent_source := null;
  elsif (select auth.role()) = 'authenticated' then
    if v_newly then
      new.sms_consent_at := now();
      new.sms_consent_source := 'office';
    else
      new.sms_consent_at := old.sms_consent_at;
      new.sms_consent_source := old.sms_consent_source;
    end if;
  end if;
  return new;
end $$;
create trigger contact_sms_consent before insert or update of phone, notify_sms, sms_consent_at, sms_consent_source on public.client_contacts
  for each row execute function private.contact_sms_consent();

revoke all on function private.phone_match_key(text), private.client_sms_consent(), private.contact_sms_consent() from public;

notify pgrst, 'reload schema';
