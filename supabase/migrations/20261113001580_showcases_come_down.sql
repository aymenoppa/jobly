-- Showcases: a public page comes down by itself when it should, and leaves nothing behind.
--
-- A showcase's photos were checked once, when it was published. After that the client could turn on
-- "don't post photos of my property", or someone could take "OK to share" off one of its photos, and
-- the page stayed up; and it stayed up with Marketing uninstalled, when the screen to unpublish it
-- is gone.
--
--   Taken down      A published showcase is unpublished, and its photos' public copies given up,
--                   when the client of its job turns on "don't post photos of my property" (or the
--                   job moves to a client who has, as a merge can do), or when one of its photos is
--                   no longer marked OK to share. showcases.unpublished_reason says why, and the
--                   office with the marketing area is told on the bell.
--   Marketing off   showcase_view answers nothing while the company's Marketing is uninstalled, so
--                   the page and its photos say "not available"; installing it again brings them
--                   back. Nothing is unpublished.
--   Server only     showcase_view was granted to everyone, and gives the company's id. Only the
--                   server calls it (apps/api/src/routes/showcases.ts, with its visitor limits), so
--                   only the server may now.
--   Copies          A photo's public copy that's no longer wanted (taken down, unpublished, or its
--                   showcase, job or client deleted) is queued in stale_public_files, and the
--                   server deletes the stored file (the plans task, daily). They were never served
--                   once unwanted; now they don't pile up either.
--   Deleting a photo in a published showcase says what to do, for a crew member who can't see
--                   showcases: ask the office to take the showcase down first.
--
-- supabase/tests/showcase_fixes_test.sql covers it.

alter table public.showcases add column unpublished_reason text check (length(unpublished_reason) <= 300);
comment on column public.showcases.unpublished_reason is 'Why it was taken down by itself (the client''s choice, a photo no longer OK to share); null when someone unpublished it';

-- ---------------------------------------------------------------------------------------------
-- Copies that are no longer wanted
-- ---------------------------------------------------------------------------------------------

-- The server's list of stored files to delete. No link to the company: a company's own deletion
-- queues its showcases' copies too, and the list is the only thing left that knows of them.
create table public.stale_public_files (
  id bigint generated always as identity primary key,
  company_id uuid not null,
  path text not null check (starts_with(path, company_id::text || '/showcases/') and path !~ '(^|/)\.\.?(/|$)' and length(path) <= 600),
  created_at timestamptz not null default now()
);
comment on table public.stale_public_files is 'Public copies of showcase photos that are no longer shown, for the server to delete from storage';
alter table public.stale_public_files enable row level security;
revoke all on public.stale_public_files from anon, authenticated;

-- Whether a showcase is being taken down right now (private.take_down_showcases), for the rest of
-- that statement's transaction: the guards below let that through, and only that.
create function private.showcase_taking_down() returns boolean
language sql stable set search_path = '' as $$
  select coalesce(current_setting('jobly.showcase_takedown', true), '') = 'on'
$$;

create function private.showcase_copy_gone() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.public_path is not null and (tg_op = 'DELETE' or new.public_path is distinct from old.public_path)
     and starts_with(old.public_path, old.company_id::text || '/showcases/') and old.public_path !~ '(^|/)\.\.?(/|$)' then
    insert into public.stale_public_files (company_id, path) values (old.company_id, left(old.public_path, 600));
  end if;
  return null;
end $$;
create trigger showcase_copy_gone after delete or update of public_path on public.showcase_photos
  for each row execute function private.showcase_copy_gone();

-- ---------------------------------------------------------------------------------------------
-- The guards, letting a take-down through
-- ---------------------------------------------------------------------------------------------

-- From 20261113001410_showcases.sql, except that a take-down (above) goes through as it is.
create or replace function private.showcase_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.role()) is distinct from 'authenticated' or private.showcase_taking_down() then
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
    new.unpublished_reason := null;
  else
    new.status := old.status;
    new.token := old.token;
    new.published_at := old.published_at;
    new.published_by := old.published_by;
    new.unpublished_at := old.unpublished_at;
    new.unpublished_reason := old.unpublished_reason;
    new.job_id := old.job_id;
  end if;
  if new.visit_id is not null and not exists (select 1 from public.visits v where v.id = new.visit_id and v.job_id = new.job_id) then
    raise exception 'That visit isn''t on this job' using errcode = '22023';
  end if;
  return new;
end $$;

-- From 20261113001410_showcases.sql, with two changes: a take-down goes through, and a photo
-- deleted while its showcase is published (the row goes with the photo) gets a message a crew
-- member can act on: they can't see showcases, so "Unpublish this showcase" told them nothing.
create or replace function private.showcase_photo_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_showcase public.showcases;
  v_attachment public.attachments;
begin
  if (select auth.role()) is distinct from 'authenticated' or private.showcase_taking_down() then
    return coalesce(new, old);
  end if;
  select * into v_showcase from public.showcases where id = coalesce(new.showcase_id, old.showcase_id);
  if v_showcase.status = 'published' then
    -- Not asked for itself: its photo is being deleted, and this row goes with it.
    if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
      raise exception 'This photo is on a published showcase, a page anyone with its link can see. Ask the office to take the showcase down first (Marketing, Showcases), then delete the photo.'
        using errcode = '22023';
    end if;
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

-- ---------------------------------------------------------------------------------------------
-- Taking one down
-- ---------------------------------------------------------------------------------------------

-- Unpublishes the published ones among p_ids, gives up their photos' public copies, says why on
-- each, and tells the people who look after marketing (private.marketing_office,
-- 20261031000300_google_reviews.sql). `p_reason` finishes "It came down because ...".
create function private.take_down_showcases(p_ids uuid[], p_reason text) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_ids uuid[];
begin
  perform set_config('jobly.showcase_takedown', 'on', true);
  with down as (
    update public.showcases s
       set status = 'unpublished', unpublished_at = now(), unpublished_reason = left(p_reason, 300)
     where s.id = any (coalesce(p_ids, '{}')) and s.status = 'published'
    returning s.id
  )
  select coalesce(array_agg(id), '{}') into v_ids from down;
  update public.showcase_photos set public_path = null where showcase_id = any (v_ids) and public_path is not null;
  perform set_config('jobly.showcase_takedown', '', true);
  insert into public.notifications (company_id, user_id, kind, title, body, link)
  select s.company_id, u, 'showcase', left('A showcase was taken down: ' || s.title, 300),
         'It came down by itself because ' || p_reason || '. Its link now says it isn''t available.', '/marketing?tab=showcases'
    from public.showcases s
    cross join lateral private.marketing_office(s.company_id) u
   where s.id = any (v_ids);
  return coalesce(array_length(v_ids, 1), 0);
end $$;

-- The client says "don't post photos of my property": their jobs' showcases come down.
create function private.showcases_follow_client_choice() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.take_down_showcases(
    array(select s.id from public.showcases s join public.jobs j on j.id = s.job_id where j.client_id = new.id and s.status = 'published'),
    'the client asked that photos of their property not be posted');
  return null;
end $$;
create trigger showcases_follow_client_choice after update of social_photos_opt_out on public.clients
  for each row when (new.social_photos_opt_out and not old.social_photos_opt_out)
  execute function private.showcases_follow_client_choice();

-- A job that moves to a client who has said so (two clients merged, or the job's client changed).
create function private.showcases_follow_job_client() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.clients c where c.id = new.client_id and c.social_photos_opt_out) then
    perform private.take_down_showcases(
      array(select s.id from public.showcases s where s.job_id = new.id and s.status = 'published'),
      'the client asked that photos of their property not be posted');
  end if;
  return null;
end $$;
create trigger showcases_follow_job_client after update of client_id on public.jobs
  for each row when (new.client_id is distinct from old.client_id)
  execute function private.showcases_follow_job_client();

-- A photo that's no longer OK to share (unmarked, or its file replaced, which unmarks it): the
-- showcases showing it come down. Not "update of shareable": a replaced file is unmarked by a
-- trigger, which that wouldn't see.
create function private.showcases_follow_photo_share() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.take_down_showcases(
    array(select s.id from public.showcase_photos p join public.showcases s on s.id = p.showcase_id where p.attachment_id = new.id and s.status = 'published'),
    'one of its photos is no longer marked OK to share');
  return null;
end $$;
create trigger showcases_follow_photo_share after update on public.attachments
  for each row when (old.shareable and not new.shareable)
  execute function private.showcases_follow_photo_share();

revoke all on function private.showcase_taking_down(), private.showcase_copy_gone(), private.take_down_showcases(uuid[], text),
  private.showcases_follow_client_choice(), private.showcases_follow_job_client(), private.showcases_follow_photo_share() from public;

-- ---------------------------------------------------------------------------------------------
-- The public page
-- ---------------------------------------------------------------------------------------------

-- From 20261113001410_showcases.sql, except that nothing is shown while the company's Marketing is
-- uninstalled. And it's the server's alone to call: it was granted to anyone without signing in,
-- which went round the server's visitor limits and gave away the company's id.
create or replace function public.showcase_view(p_token text) returns jsonb
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
    join public.companies c on c.id = s.company_id
    join public.jobs j on j.id = s.job_id
    left join public.properties p on p.id = j.property_id
   where s.token = p_token and s.status = 'published'
     and c.settings -> 'marketing' ->> 'enabled' = 'true'
$$;
revoke execute on function public.showcase_view(text) from public, anon, authenticated;
grant execute on function public.showcase_view(text) to service_role;

notify pgrst, 'reload schema';
