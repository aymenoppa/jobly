-- A bot check for website forms (Apps → Jobly - Website Forms and Careers; the address a form
-- posts to is /f/<key>, apps/api/src/routes/websiteForms.ts). The hidden field, the limits and Only
-- these websites stay as they are. On top of them, each form chooses one of:
--
--   off        nothing more (every form before this, and every new one)
--   script     Jobly's own check: one <script> line on the page gets a signed token from the
--              form's own Jobly and sends it with the message
--   turnstile  Cloudflare Turnstile, with the business's own keys (website_form_turnstile)
--
-- Turning a check on only watches. The form's HTML is the business's own, on its own website, often
-- on more than one page, and a message from a page that doesn't have the line yet is still a lead.
-- So the server notes what it sees, for the form's current check and address, and the form refuses
-- messages without the check only once an owner or admin says so, which they can't until a message
-- has come through with it. Nothing arms by itself: anyone can send one message that passes.
-- Changing the check, getting a new address or changing the Turnstile keys starts all of it over.
--
--   website_forms.bot_check            off, script or turnstile
--   website_forms.bot_check_passed_at  when a message last passed the check (noted once it's kept)
--   website_forms.bot_check_missed     messages kept while the check was on that didn't pass it:
--                                      a page without the line, or a bot (nothing tells them apart)
--   website_forms.bot_check_missed_at  when the last of those was
--   website_forms.bot_check_armed_at   refusing since: set by the server when an owner or admin
--                                      who connects apps turns refusing on, cleared when they stop
--   website_forms.bots_blocked         how many were turned away: a filled-in hidden field, or a
--                                      message the check refused
--   website_forms.last_blocked_at      when the last one was
--   website_form_turnstile             the business's Turnstile keys, for all its forms: the site
--                                      key (it's in the website's HTML anyway) and the secret key,
--                                      encrypted by the server before it arrives. Only the server
--                                      reads or writes it.
--
-- supabase/tests/form_bot_checks_test.sql covers it.

alter table public.website_forms
  add column bot_check text not null default 'off' check (bot_check in ('off', 'script', 'turnstile')),
  add column bot_check_passed_at timestamptz,
  add column bot_check_missed integer not null default 0 check (bot_check_missed >= 0),
  add column bot_check_missed_at timestamptz,
  add column bot_check_armed_at timestamptz,
  add column bots_blocked integer not null default 0 check (bots_blocked >= 0),
  add column last_blocked_at timestamptz,
  -- Refusing needs a check, and a message that has passed it.
  add constraint website_forms_refusing_check check (bot_check_armed_at is null or (bot_check <> 'off' and bot_check_passed_at is not null));
comment on column public.website_forms.bot_check is 'What keeps bots out beyond the hidden field: off, script (Jobly''s own check) or turnstile (Cloudflare, with the keys in website_form_turnstile).';
comment on column public.website_forms.bot_check_passed_at is 'When a message last passed the form''s current check, at its current address.';
comment on column public.website_forms.bot_check_missed is 'Messages kept while the check was on that didn''t pass it: a page without the line, or a bot.';
comment on column public.website_forms.bot_check_armed_at is 'Refusing messages without the check since then: an owner or admin turned it on. Null: the check only watches.';
comment on column public.website_forms.bots_blocked is 'Messages turned away: the hidden field was filled in, or the check refused them.';

-- RLS on and no policies, as integration_secrets: only the service key reads or writes.
create table public.website_form_turnstile (
  company_id uuid primary key references public.companies (id) on delete cascade,
  site_key text not null check (site_key ~ '^[0-9A-Za-z_-]{10,100}$'),
  ciphertext text not null,
  updated_at timestamptz not null default now()
);
comment on table public.website_form_turnstile is 'A business''s Cloudflare Turnstile keys for its website forms. The secret key is AES-GCM encrypted by the API.';
alter table public.website_form_turnstile enable row level security;
revoke all on public.website_form_turnstile from authenticated, anon;

-- What the people who manage forms choose in the browser is the check; what came of it, and
-- whether it refuses, are the server's (the app's page asks the server to start or stop refusing).
-- A form can't ask for Turnstile before the business has keys, and a changed check or a new address
-- starts over: nothing passed, nothing missed, nothing refused.
create function private.website_form_bot_check_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_browser boolean := (select auth.role()) is not distinct from 'authenticated';
begin
  if tg_op = 'INSERT' then
    if v_browser then
      new.bot_check_passed_at := null;
      new.bot_check_missed := 0;
      new.bot_check_missed_at := null;
      new.bot_check_armed_at := null;
      new.bots_blocked := 0;
      new.last_blocked_at := null;
    end if;
  else
    if new.bot_check is distinct from old.bot_check or new.key is distinct from old.key then
      new.bot_check_passed_at := null;
      new.bot_check_missed := 0;
      new.bot_check_missed_at := null;
      new.bot_check_armed_at := null;
    elsif v_browser then
      new.bot_check_passed_at := old.bot_check_passed_at;
      new.bot_check_missed := old.bot_check_missed;
      new.bot_check_missed_at := old.bot_check_missed_at;
      new.bot_check_armed_at := old.bot_check_armed_at;
    end if;
    if v_browser then
      new.bots_blocked := old.bots_blocked;
      new.last_blocked_at := old.last_blocked_at;
    end if;
  end if;
  if new.bot_check = 'turnstile' and (tg_op = 'INSERT' or old.bot_check is distinct from 'turnstile')
     and not exists (select 1 from public.website_form_turnstile t where t.company_id = new.company_id) then
    raise exception 'Add your Turnstile keys first' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger website_form_bot_check_guard before insert or update on public.website_forms
  for each row execute function private.website_form_bot_check_guard();

-- Without its keys a form can't check anything: the business's Turnstile forms go back to the
-- hidden field only. (Not when the whole business is going: its forms go with it.)
create function private.website_form_turnstile_removed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.companies c where c.id = old.company_id) then
    update public.website_forms set bot_check = 'off' where company_id = old.company_id and bot_check = 'turnstile';
  end if;
  return null;
end $$;
create trigger website_form_turnstile_removed after delete on public.website_form_turnstile
  for each row execute function private.website_form_turnstile_removed();

-- New keys are usually a new widget, and the one on the website still has the old site key: the
-- business's Turnstile forms start over, so nothing is refused while the website catches up.
create function private.website_form_turnstile_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.site_key is distinct from old.site_key or new.ciphertext is distinct from old.ciphertext then
    update public.website_forms
    set bot_check_passed_at = null, bot_check_missed = 0, bot_check_missed_at = null, bot_check_armed_at = null
    where company_id = new.company_id and bot_check = 'turnstile';
  end if;
  return null;
end $$;
create trigger website_form_turnstile_changed after update on public.website_form_turnstile
  for each row execute function private.website_form_turnstile_changed();
revoke all on function private.website_form_bot_check_guard(), private.website_form_turnstile_removed(), private.website_form_turnstile_changed() from public;

-- One more turned away, for the form's page ("12 turned away"). The server's, as the service role.
create function public.website_form_blocked(p_form uuid) returns void
language sql security definer set search_path = '' as $$
  update public.website_forms set bots_blocked = bots_blocked + 1, last_blocked_at = now() where id = p_form
$$;

-- What the server saw of a message it kept while the form's check was on: it passed, or it didn't.
-- Only for the check and the address the message was judged by, so one that was changed a moment
-- ago isn't told about a message from before. The server's, as the service role.
create function public.website_form_check_noted(p_form uuid, p_check text, p_key text, p_passed boolean) returns void
language sql security definer set search_path = '' as $$
  update public.website_forms set
    bot_check_passed_at = case when p_passed then now() else bot_check_passed_at end,
    bot_check_missed = bot_check_missed + case when p_passed then 0 else 1 end,
    bot_check_missed_at = case when p_passed then bot_check_missed_at else now() end
  where id = p_form and bot_check = p_check and key = p_key and bot_check <> 'off'
$$;
revoke execute on function public.website_form_blocked(uuid), public.website_form_check_noted(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function public.website_form_blocked(uuid), public.website_form_check_noted(uuid, text, text, boolean) to service_role;

notify pgrst, 'reload schema';
