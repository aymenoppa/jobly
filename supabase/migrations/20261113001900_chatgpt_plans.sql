-- A person's own ChatGPT plan for Jobly's AI (Apps → ChatGPT, Continue with ChatGPT). Someone on
-- the team signs in with their ChatGPT account, and what they ask Jobly's AI for themselves is
-- then answered on their plan (OpenAI's Sign in with ChatGPT plan use). A sign-in belongs to the
-- person, never the company: it isn't used for anyone else's asks or for what Jobly does by
-- itself, which stay on the company's own key (apps/api/src/services/ai.ts).
--
--   chatgpt_plans          one row for a person at a company: whether their plan is connected, the
--                          account it is (for the label), the model they picked among the ones
--                          OpenAI lists for them, and what's in the way when the plan can't be used
--                          (the usage limit, a sign-in to do again). The person sees their own row;
--                          nobody else's. Nothing secret is in it.
--   chatgpt_plan_secrets   the sign-in's tokens, sealed by the server before they arrive (as
--                          integration_secrets are). Only the server reads or writes them.
--   chatgpt_sign_ins       sign-ins under way: what the server needs to finish one (sealed), found
--                          by the one-time value OpenAI hands back. Gone once used, or after ten minutes.
--   chatgpt_host           this Jobly's own id at OpenAI, made once and kept.
--
-- Someone who leaves the company (or is turned off on the Team page) loses their connection at
-- once; the server then signs the tokens out at OpenAI and deletes them (the chatgpt_plans task).
-- The tokens table has no foreign keys for that reason: they outlive their row just long enough to
-- be signed out.

create table public.chatgpt_plans (
  user_id uuid not null references auth.users (id) on delete cascade,
  company_id uuid not null references public.companies (id) on delete cascade,
  status text not null default 'disconnected' check (status in ('connected', 'disconnected')),
  -- The client OpenAI registered for this account at this Jobly. Kept after signing out, so
  -- signing in again is the same registration.
  client_id text check (char_length(client_id) between 1 and 200),
  host_id text check (char_length(host_id) <= 100),
  account_sub text check (char_length(account_sub) <= 300),
  account_email text check (char_length(account_email) <= 320),
  model text check (char_length(model) <= 200),
  -- The models OpenAI listed for the plan when it was last asked: [{slug, display_name}].
  models jsonb not null default '[]',
  -- Kinds of ask the plan turned down as unsupported, so they aren't sent to it again.
  unsupported text[] not null default '{}',
  problem text check (problem in ('usage_limit', 'sign_in', 'not_eligible')),
  problem_at timestamptz,
  -- When the plan is tried again after a problem. Null with a problem: not until the person acts.
  retry_at timestamptz,
  -- When the person dismissed "You're using your ChatGPT plan", shown once.
  notice_seen_at timestamptz,
  connected_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, company_id)
);
comment on table public.chatgpt_plans is 'A person''s own ChatGPT plan, connected for what they ask Jobly''s AI themselves at one company. No tokens: those are in chatgpt_plan_secrets.';
create index chatgpt_plans_company_idx on public.chatgpt_plans (company_id);
create trigger touch_updated_at before update on public.chatgpt_plans for each row execute function private.touch_updated_at();
alter table public.chatgpt_plans enable row level security;
-- A person on the team sees their own row. Not a sub, not anyone else's, and not an AI assistant
-- acting for them. The server writes it, with the service key.
create policy chatgpt_plans_read on public.chatgpt_plans for select to authenticated
  using (user_id = (select auth.uid()) and private.is_member(company_id) and (select private.assistant_client()) is null);
revoke all on public.chatgpt_plans from anon, authenticated;
grant select on public.chatgpt_plans to authenticated;

-- RLS on and no policies: only the service key can read or write.
create table public.chatgpt_plan_secrets (
  user_id uuid not null,
  company_id uuid not null,
  ciphertext text not null,
  expires_at timestamptz,
  -- A server that is refreshing the tokens holds them until then, so two never use one refresh token.
  refresh_claimed_until timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, company_id)
);
alter table public.chatgpt_plan_secrets enable row level security;
revoke all on public.chatgpt_plan_secrets from anon, authenticated;

create table public.chatgpt_sign_ins (
  state text primary key check (char_length(state) between 20 and 200),
  user_id uuid not null references auth.users (id) on delete cascade,
  company_id uuid not null references public.companies (id) on delete cascade,
  ciphertext text not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index chatgpt_sign_ins_person_idx on public.chatgpt_sign_ins (user_id, company_id);
alter table public.chatgpt_sign_ins enable row level security;
revoke all on public.chatgpt_sign_ins from anon, authenticated;

create table private.chatgpt_host (
  one_row boolean primary key default true check (one_row),
  id uuid not null default gen_random_uuid()
);
alter table private.chatgpt_host enable row level security;
revoke all on private.chatgpt_host from public, anon, authenticated;

/** This Jobly's id at OpenAI (ext_agent_host_id), made the first time it's asked for and the same ever after. */
create function public.chatgpt_host_id() returns text
language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  insert into private.chatgpt_host default values on conflict do nothing;
  select h.id into v_id from private.chatgpt_host h;
  return 'urn:uuid:' || v_id::text;
end $$;
revoke execute on function public.chatgpt_host_id() from public, anon, authenticated;
grant execute on function public.chatgpt_host_id() to service_role;

/**
 * One server at a time refreshes a person's tokens: OpenAI replaces the refresh token on every use,
 * and two servers run side by side during an update. Whoever gets the tokens back (sealed, as
 * stored now) holds them for 30 seconds; anyone else gets null and waits for the new ones to be saved.
 */
create function public.claim_chatgpt_plan_refresh(p_user uuid, p_company uuid) returns text
language sql security definer set search_path = '' as $$
  update public.chatgpt_plan_secrets s
  set refresh_claimed_until = now() + interval '30 seconds'
  where s.user_id = p_user and s.company_id = p_company
    and (s.refresh_claimed_until is null or s.refresh_claimed_until < now())
  returning s.ciphertext
$$;
revoke execute on function public.claim_chatgpt_plan_refresh(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_chatgpt_plan_refresh(uuid, uuid) to service_role;

/**
 * Tokens with nobody to use them: no connected plan for that person at that company (they signed
 * out, left, were turned off, or their account or the company is gone). The server signs each out
 * at OpenAI, then deletes it. Not ones saved in the last two minutes: a sign-in being finished
 * right now saves its tokens a moment before its plan says connected.
 */
create function public.chatgpt_plan_leftovers(p_limit integer default 50)
returns table (user_id uuid, company_id uuid, ciphertext text, client_id text)
language sql stable security definer set search_path = '' as $$
  select s.user_id, s.company_id, s.ciphertext, p.client_id
  from public.chatgpt_plan_secrets s
  left join public.chatgpt_plans p on p.user_id = s.user_id and p.company_id = s.company_id
  where (p.user_id is null or p.status <> 'connected') and s.updated_at < now() - interval '2 minutes'
  order by s.updated_at
  limit greatest(1, least(coalesce(p_limit, 50), 200))
$$;
revoke execute on function public.chatgpt_plan_leftovers(integer) from public, anon, authenticated;
grant execute on function public.chatgpt_plan_leftovers(integer) to service_role;

-- Leaving the company, or being turned off on the Team page, ends the connection at once: the
-- plan is never used for someone who isn't on the team. So does stopping being an owner or admin
-- at a company that doesn't let its whole team use their own plans (settings.ai.team_plans), since
-- only owners and admins can connect one there. Their tokens go on the server's next pass.
create function private.chatgpt_plan_leaves_with_member() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.active and new.role <> 'subcontractor' then
    if new.role in ('owner', 'admin') or exists (
      select 1 from public.companies c where c.id = new.company_id and c.settings -> 'ai' -> 'team_plans' = 'true'::jsonb
    ) then
      return null;
    end if;
  end if;
  update public.chatgpt_plans p
  set status = 'disconnected', problem = null, problem_at = null, retry_at = null
  where p.user_id = old.user_id and p.company_id = old.company_id and p.status = 'connected';
  return null;
end $$;
revoke all on function private.chatgpt_plan_leaves_with_member() from public;
create trigger chatgpt_plan_leaves after delete on public.memberships
  for each row execute function private.chatgpt_plan_leaves_with_member();
create trigger chatgpt_plan_turned_off after update of active, role on public.memberships
  for each row when (old.active is distinct from new.active or old.role is distinct from new.role)
  execute function private.chatgpt_plan_leaves_with_member();

-- Which key Jobly's AI uses, and whether the team may connect their own plans (settings.ai),
-- decide who pays and where what people ask is sent: like the other apps' settings, only someone
-- with the apps area changes them, whichever way the settings are written. (Beside
-- settings_area_guard, 20261112000500, which this leaves as it is.)
create function private.company_ai_settings_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null or new.settings -> 'ai' is not distinct from old.settings -> 'ai' or private.has_perm(new.id, 'apps') then
    return new;
  end if;
  new.settings := case when old.settings -> 'ai' is null then coalesce(new.settings, '{}') - 'ai'
    else jsonb_set(coalesce(new.settings, '{}'), '{ai}', old.settings -> 'ai') end;
  return new;
end $$;
revoke all on function private.company_ai_settings_guard() from public;
create trigger ai_settings_guard before update of settings on public.companies
  for each row execute function private.company_ai_settings_guard();

-- A company that stops letting its whole team connect their own plans: everyone's but the owners'
-- and admins' ends at once, however the setting was changed. Their tokens go on the server's next pass.
create function private.chatgpt_team_plans_end() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.chatgpt_plans p
  set status = 'disconnected', problem = null, problem_at = null, retry_at = null
  where p.company_id = new.id and p.status = 'connected'
    and not exists (
      select 1 from public.memberships m
      where m.company_id = p.company_id and m.user_id = p.user_id and m.active and m.role in ('owner', 'admin'));
  return null;
end $$;
revoke all on function private.chatgpt_team_plans_end() from public;
create trigger chatgpt_team_plans_end after update of settings on public.companies
  for each row when (old.settings -> 'ai' -> 'team_plans' = 'true'::jsonb and new.settings -> 'ai' -> 'team_plans' is distinct from 'true'::jsonb)
  execute function private.chatgpt_team_plans_end();

-- Its policy looks the person's memberships up once a query, not once a row (20261018000990_policy_lookups.sql).
select private.fold_member_checks('public.chatgpt_plans');

notify pgrst, 'reload schema';
