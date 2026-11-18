-- Job showcases: a finished job (or one of its visits) turned into a page anyone with the link can
-- see: before and after photos, a title and a short write-up, in the company's colours, with a
-- "Get a quote" button to its booking form (apps/api/src/routes/showcases.ts, /s/<token> in the app).
--
--   showcases         the write-up, whether the town is shown (off by default; the client's name and
--                     address never are), and whether it's published. The office writes a showcase
--                     that isn't published from the browser; publishing and unpublishing are the
--                     server's, which checks the photos and the words first (showcase_guard).
--   showcase_photos   the photos it shows, each marked before, after or neither, and whether it
--                     shows the photo's drawn-on copy. `public_path` is a copy the server makes when
--                     it publishes: re-encoded without EXIF (a phone photo's location would say
--                     where the client lives), in the showcase's own folder
--                     (<company>/showcases/<showcase>/). Unpublishing deletes the copies.
--
-- Why copies: the files bucket is private, read by the team under rules that follow their records
-- (20261112000100_crew_files.sql), and a link signed for a visitor would point at the address this
-- server reaches Storage by, which in stack mode is its own 127.0.0.1. So the public page's photos
-- come through the server (/api/public/showcases/<token>/<photo>.jpg), only while the showcase is
-- published, only those it shows, and never the original file: what's served is the copy made for
-- the page, which can't change the job's photos and is gone once it's unpublished.
--
-- Anyone without signing in reads a showcase only through public.showcase_view, and only while it's
-- published; it says nothing of the client. supabase/tests/showcases_test.sql covers it.

create table public.showcases (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  job_id uuid not null,
  -- The visit it was made from, when it was made from one (its photos are picked first).
  visit_id uuid references public.visits (id) on delete set null,
  title text not null check (length(trim(title)) between 1 and 120),
  description text not null default '' check (length(description) <= 2000),
  show_town boolean not null default false,
  status text not null default 'draft' check (status in ('draft', 'published', 'unpublished')),
  token text not null unique default replace(gen_random_uuid()::text, '-', '') check (token ~ '^[0-9a-f]{32}$'),
  published_at timestamptz,
  published_by uuid references auth.users (id) on delete set null,
  unpublished_at timestamptz,
  created_by uuid references auth.users (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade
);
create index showcases_company_idx on public.showcases (company_id, created_at desc);
create index showcases_job_idx on public.showcases (job_id);
comment on table public.showcases is 'A finished job''s before and after photos and write-up, on a public page by its token while published';

create table public.showcase_photos (
  id bigint generated always as identity primary key,
  company_id uuid not null,
  showcase_id uuid not null,
  attachment_id uuid not null references public.attachments (id) on delete cascade,
  role text not null default 'photo' check (role in ('before', 'after', 'photo')),
  -- Its drawn-on copy, when it has one; false for the photo as taken.
  use_marked boolean not null default true,
  sort integer not null default 0,
  public_path text,
  unique (showcase_id, attachment_id),
  foreign key (company_id, showcase_id) references public.showcases (company_id, id) on delete cascade
);
create index showcase_photos_showcase_idx on public.showcase_photos (showcase_id, sort, id);
create index showcase_photos_attachment_idx on public.showcase_photos (attachment_id);

select private.add_touch_triggers(array['showcases']);
select private.apply_policies('showcases', '{owner,admin,office}', '{owner,admin,office}');
select private.restrict_area('showcases', 'marketing', true);
select private.apply_policies('showcase_photos', '{owner,admin,office}', '{owner,admin,office}');
select private.restrict_area('showcase_photos', 'marketing', true);
revoke all on public.showcases, public.showcase_photos from anon;
revoke truncate on public.showcases, public.showcase_photos from authenticated;

-- In the browser, a showcase is written while it isn't published: what it says, which photos and
-- which visit, of this company's job. Publishing, unpublishing and the public copies are the
-- server's. A published one is unpublished first to change it, so nothing goes on the page that the
-- server didn't check.
create function private.showcase_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.role()) is distinct from 'authenticated' then
    return coalesce(new, old);
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  if tg_op = 'UPDATE' and old.status = 'published' then
    raise exception 'Unpublish this showcase to change it' using errcode = '22023';
  end if;
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.token := replace(gen_random_uuid()::text, '-', '');
    new.published_at := null;
    new.published_by := null;
    new.unpublished_at := null;
  else
    new.status := old.status;
    new.token := old.token;
    new.published_at := old.published_at;
    new.published_by := old.published_by;
    new.unpublished_at := old.unpublished_at;
    new.job_id := old.job_id;
  end if;
  if new.visit_id is not null and not exists (select 1 from public.visits v where v.id = new.visit_id and v.job_id = new.job_id) then
    raise exception 'That visit isn''t on this job' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger showcase_guard before insert or update or delete on public.showcases
  for each row execute function private.showcase_guard();

-- A showcase's photos are the job's own (its own, its visits' or its quote's), changed while it
-- isn't published; their public copies are the server's.
create function private.showcase_photo_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_showcase public.showcases;
  v_attachment public.attachments;
begin
  if (select auth.role()) is distinct from 'authenticated' then
    return coalesce(new, old);
  end if;
  select * into v_showcase from public.showcases where id = coalesce(new.showcase_id, old.showcase_id);
  if v_showcase.status = 'published' then
    raise exception 'Unpublish this showcase to change its photos' using errcode = '22023';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  if tg_op = 'UPDATE' then
    new.public_path := old.public_path;
    new.attachment_id := old.attachment_id;
    new.showcase_id := old.showcase_id;
  else
    new.public_path := null;
  end if;
  select * into v_attachment from public.attachments where id = new.attachment_id;
  if v_attachment.id is null or v_attachment.company_id <> v_showcase.company_id
     or private.attachment_job(v_showcase.company_id, v_attachment.owner_type, v_attachment.owner_id) is distinct from v_showcase.job_id then
    raise exception 'A showcase shows this job''s own photos' using errcode = '22023';
  end if;
  return new;
end $$;
create trigger showcase_photo_guard before insert or update or delete on public.showcase_photos
  for each row execute function private.showcase_photo_guard();
revoke all on function private.showcase_guard(), private.showcase_photo_guard() from public;

-- A published showcase, for anyone with its link (the server's public route reads it): what it
-- says, the town when it's shown, the company it's for, and its photos (their ids here, never the
-- files or the client's). Null when there's no such showcase or it isn't published.
create function public.showcase_view(p_token text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'company_id', s.company_id,
    'title', s.title,
    'description', s.description,
    'town', case when s.show_town then nullif(trim(p.city), '') end,
    'region', case when s.show_town and nullif(trim(p.city), '') is not null then nullif(trim(p.region), '') end,
    'published_at', s.published_at,
    'photos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'role', x.role) order by x.sort, x.id)
                          from public.showcase_photos x where x.showcase_id = s.id and x.public_path is not null), '[]'::jsonb))
    from public.showcases s
    join public.jobs j on j.id = s.job_id
    left join public.properties p on p.id = j.property_id
   where s.token = p_token and s.status = 'published'
$$;
revoke execute on function public.showcase_view(text) from public;
grant execute on function public.showcase_view(text) to anon, authenticated, service_role;

select private.fold_member_checks('public.showcases');
select private.fold_member_checks('public.showcase_photos');

notify pgrst, 'reload schema';
