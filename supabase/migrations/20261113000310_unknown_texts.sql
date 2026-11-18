-- Texts from numbers nobody recognises. The Twilio webhook matched a text to clients.phone only: one
-- from a contact's phone, or from a number that isn't on file, was dropped and nobody was told. A
-- contact's number is now matched too (messages.from_phone and from_name say who sent it). A text
-- from a number that's nobody's is kept here, the office hears on the bell, and Messages lists these
-- under "Unknown numbers" until someone attaches the number to a client, which moves the
-- conversation onto that client's timeline.
--
-- A table of its own, not messages with no client: messages rows without a client are read by crew
-- leads too (messages_read), and every screen and export that lists messages expects a client.
--
-- The server writes it, capped for each number a day (routes/messages.ts). The office reads it,
-- attaches a number (attach_unknown_texts) or deletes what it doesn't want.
--
-- supabase/tests/unknown_texts_test.sql covers it.

create table public.unknown_texts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  -- The number as Twilio gave it ("+15125550163"), and its last 10 digits for matching (core phoneMatchKey).
  from_phone text not null check (char_length(from_phone) <= 40),
  phone_key text not null check (phone_key ~ '^[0-9]{7,10}$'),
  body text not null check (char_length(body) <= 10000),
  external_id text,
  created_at timestamptz not null default now()
);
create index unknown_texts_number_idx on public.unknown_texts (company_id, phone_key, created_at desc);
comment on table public.unknown_texts is 'Texts that came in from a number that isn''t a client''s or a contact''s, until someone attaches the number to a client.';

alter table public.unknown_texts enable row level security;
revoke insert, update on public.unknown_texts from authenticated;
-- Whoever starts conversations with clients in Messages: the office and estimators.
create policy unknown_texts_read on public.unknown_texts for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office,estimator}'));
create policy unknown_texts_delete on public.unknown_texts for delete to authenticated
  using (private.has_role(company_id, '{owner,admin,office}'));
select private.fold_member_checks('public.unknown_texts');

-- Nobody signed in sets or clears a client's text opt-out (client_sms_opt_out_guard). As in
-- 20261106000100_client_merge.sql, which lets a merge keep the merged client's, and one more: a
-- number attached as the client's phone brings the STOP it sent (attach_unknown_texts, below, names
-- the client in jobly.attach_text while it writes).
create or replace function private.client_sms_opt_out_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.role()) = 'authenticated'
     and not (tg_op = 'UPDATE' and (private.merging_clients(null, new.id) or coalesce(current_setting('jobly.attach_text', true), '') = new.id::text)) then
    if tg_op = 'UPDATE' then
      new.sms_opt_out_at := old.sms_opt_out_at;
    else
      new.sms_opt_out_at := null;
    end if;
  end if;
  return new;
end $$;

/**
 * Attaches an unknown number to a client and moves its texts onto their timeline: as the client's
 * own phone (p_as 'phone', replacing the one on file), or as a new contact named p_name (p_as
 * 'contact'; not ticked for reminders, which is for the office to choose). For whoever may edit
 * clients. A number that texted STOP stays stopped: as the client's phone, they have texts off.
 * Returns how many texts moved.
 */
create function public.attach_unknown_texts(p_company uuid, p_phone text, p_client uuid, p_as text default 'contact', p_name text default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_key text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  v_from text;
  v_client text;
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_stopped timestamptz;
  v_moved integer;
begin
  if not private.has_role(p_company, '{owner,admin,office,estimator}') then
    raise exception 'Only the office can attach a number to a client.' using errcode = '42501';
  end if;
  if p_as is null or p_as not in ('phone', 'contact') then
    raise exception 'Attach the number as the client''s phone or as a contact.' using errcode = '22023';
  end if;
  select display_name into v_client from public.clients where company_id = p_company and id = p_client for update;
  if v_client is null then
    raise exception 'That client isn''t here anymore.' using errcode = 'P0002';
  end if;
  -- The number as it texted, from its newest text.
  select from_phone into v_from from public.unknown_texts
   where company_id = p_company and phone_key = v_key order by created_at desc limit 1;
  if v_from is null then
    raise exception 'There are no texts from that number to attach.' using errcode = 'P0002';
  end if;
  if p_as = 'contact' and v_name is null then
    raise exception 'Add the contact''s name.' using errcode = '22023';
  end if;
  select stopped_at into v_stopped from public.sms_stops where company_id = p_company and phone_key = v_key;

  if p_as = 'phone' then
    -- The STOP is the number's, and the number is now theirs (the guard lets this one write through).
    perform set_config('jobly.attach_text', p_client::text, true);
    update public.clients set phone = v_from, sms_opt_out_at = coalesce(v_stopped, sms_opt_out_at) where company_id = p_company and id = p_client;
    perform set_config('jobly.attach_text', '', true);
  else
    insert into public.client_contacts (company_id, client_id, name, phone, notify_email, notify_sms)
    values (p_company, p_client, left(v_name, 120), v_from, false, false);
  end if;

  insert into public.messages (company_id, client_id, channel, direction, status, body, external_id, sent_by, created_at, from_phone, from_name)
  select u.company_id, p_client, 'sms', 'in', 'received', u.body, u.external_id, null, u.created_at, u.from_phone,
         case when p_as = 'contact' then left(v_name, 200) end
    from public.unknown_texts u
   where u.company_id = p_company and u.phone_key = v_key
   order by u.created_at;
  get diagnostics v_moved = row_count;
  delete from public.unknown_texts where company_id = p_company and phone_key = v_key;
  return v_moved;
end $$;
revoke execute on function public.attach_unknown_texts(uuid, text, uuid, text, text) from public, anon;
grant execute on function public.attach_unknown_texts(uuid, text, uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
