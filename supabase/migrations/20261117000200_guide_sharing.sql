-- Sharing a guide by link, with people outside the team: a new hire who has no sign-in yet, a
-- subcontractor, a client who asked how to look after what was installed. The team reads guides in
-- Jobly as before; this is the same guide on a page of its own (/g/<token> in the app,
-- apps/api/src/routes/guideShares.ts), for whoever the business chooses, the way a shared document
-- works:
--
--   restricted   only the people the business adds, by email address. Each proves the address is
--                theirs with a code emailed to it. With nobody added, nobody outside the team can
--                open it: this is how every guide starts.
--   anyone       anyone who has the link.
--
--   sop_shares         a guide's link (a random token, which can be swapped for a new one) and who
--                      may open it. Made the first time an owner or admin opens Share on the guide.
--   sop_share_people   the people added, and when each last opened it.
--
-- Owners and admins who edit guides decide who a guide is shared with; office staff who edit
-- guides see that it's shared, since what they write shows on the shared page. Nobody else sees
-- either table. Only a published guide is shown: a draft's link says it isn't available, and so
-- does a deleted guide's. Anyone without a sign-in reads a guide only through
-- public.guide_share_view, as the server. supabase/tests/guide_sharing_test.sql covers it.

create table public.sop_shares (
  page_id uuid primary key,
  company_id uuid not null references public.companies (id) on delete cascade,
  token text not null unique default replace(gen_random_uuid()::text, '-', '') check (token ~ '^[0-9a-f]{32}$'),
  access text not null default 'restricted' check (access in ('restricted', 'anyone')),
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, page_id),
  foreign key (company_id, page_id) references public.sop_pages (company_id, id) on delete cascade
);
create index sop_shares_company_idx on public.sop_shares (company_id);
comment on table public.sop_shares is 'A guide''s link for people outside the team (/g/<token>), and whether anyone with it or only the people added may open it';

create table public.sop_share_people (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  page_id uuid not null,
  -- One spelling, as emailKey() in packages/core/src/email.ts and private.email_key spell them.
  email text not null check (email = lower(trim(email)) and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  added_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  -- When they last opened the guide with a code sent to this address. The server's to set.
  last_opened_at timestamptz,
  unique (page_id, email),
  foreign key (company_id, page_id) references public.sop_shares (company_id, page_id) on delete cascade
);
create index sop_share_people_company_idx on public.sop_share_people (company_id);
comment on table public.sop_share_people is 'The people a guide is shared with by email address (sop_shares.access restricted)';

select private.add_touch_triggers(array['sop_shares']);

-- Office staff who edit guides see who a guide is shared with; owners and admins who edit guides
-- decide it.
select private.apply_policies('sop_shares', '{owner,admin}', '{owner,admin,office}');
select private.restrict_area('sop_shares', 'kb_edit', true);
select private.apply_policies('sop_share_people', '{owner,admin}', '{owner,admin,office}');
select private.restrict_area('sop_share_people', 'kb_edit', true);
revoke all on public.sop_shares, public.sop_share_people from anon;
revoke truncate on public.sop_shares, public.sop_share_people from authenticated;

-- In the browser, a share's link is never chosen: a new share gets a random one, and it stays until
-- the server swaps it (Get a new link). The guide it's for doesn't change either.
create function private.sop_share_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.role()) is distinct from 'authenticated' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.token := replace(gen_random_uuid()::text, '-', '');
    new.created_by := (select auth.uid());
  else
    new.token := old.token;
    new.page_id := old.page_id;
    new.company_id := old.company_id;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
create trigger sop_share_guard before insert or update on public.sop_shares
  for each row execute function private.sop_share_guard();

-- A person is added once per guide, up to 50 a guide, and stays the address they were added as.
-- When they opened it is the server's to say.
create function private.sop_share_person_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if (select count(*) from public.sop_share_people p where p.page_id = new.page_id) >= 50 then
      raise exception 'A guide can be shared with up to 50 people. To reach more, let anyone with the link open it.' using errcode = '22023';
    end if;
  end if;
  if (select auth.role()) is distinct from 'authenticated' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    new.added_by := (select auth.uid());
    new.created_at := now();
    new.last_opened_at := null;
  else
    new.email := old.email;
    new.page_id := old.page_id;
    new.company_id := old.company_id;
    new.added_by := old.added_by;
    new.created_at := old.created_at;
    new.last_opened_at := old.last_opened_at;
  end if;
  return new;
end $$;
create trigger sop_share_person_guard before insert or update on public.sop_share_people
  for each row execute function private.sop_share_person_guard();
revoke all on function private.sop_share_guard(), private.sop_share_person_guard() from public;

-- A shared guide, for whoever opens its link (the server's public route reads it). Null when there's
-- no such link, or the guide isn't published. Otherwise whose it is and whether this reader may open
-- it: anyone when the link is for anyone, or the person whose address this is (p_email, which the
-- server only passes once a code sent to it was typed back) when they've been added. Only then does
-- it say anything of the guide. p_opened notes that they opened it just now. p_person is the same
-- person by their row here instead of their address: what the page's pictures are asked for with, so
-- no address is ever written into a picture's link.
create function public.guide_share_view(p_token text, p_email text default null, p_opened boolean default false, p_person uuid default null) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  s public.sop_shares;
  g public.sop_pages;
  v_email text := private.email_key(p_email);
  v_person uuid;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{32}$' then
    return null;
  end if;
  select * into s from public.sop_shares where token = p_token;
  if not found then
    return null;
  end if;
  select * into g from public.sop_pages where id = s.page_id and status = 'published';
  if not found then
    return null;
  end if;
  if v_email is not null then
    select p.id into v_person from public.sop_share_people p where p.page_id = s.page_id and p.email = v_email;
  elsif p_person is not null then
    select p.id into v_person from public.sop_share_people p where p.page_id = s.page_id and p.id = p_person;
  end if;
  if s.access <> 'anyone' and v_person is null then
    return jsonb_build_object('company_id', s.company_id, 'page_id', s.page_id, 'access', s.access, 'allowed', false);
  end if;
  if p_opened and v_person is not null then
    update public.sop_share_people set last_opened_at = now() where id = v_person;
  end if;
  return jsonb_build_object(
    'company_id', s.company_id, 'page_id', s.page_id, 'access', s.access, 'allowed', true, 'person_id', v_person,
    'title', g.title, 'body_html', g.body_html, 'cover_path', g.cover_path, 'revised_at', g.revised_at,
    'category', (select c.name from public.sop_categories c where c.id = g.category_id)
  );
end $$;
revoke execute on function public.guide_share_view(text, text, boolean, uuid) from public, anon, authenticated;
grant execute on function public.guide_share_view(text, text, boolean, uuid) to service_role;

select private.fold_member_checks('public.sop_shares');
select private.fold_member_checks('public.sop_share_people');

notify pgrst, 'reload schema';
