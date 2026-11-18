-- Photos drawn on: a marked-up copy kept beside the original.
--
-- The crew and the office can draw on a photo (arrows, circles, boxes, a pen, words: the photo
-- editor in the web app). The photo as taken is never changed. The drawing is saved as a copy, a
-- new file, and the photo's row points at it:
--
--   attachments.marked_path   The marked-up copy, a JPEG in the same folder as the original, so
--                             exactly the people who can read the original can read it (the files
--                             bucket goes by the folder: 20261112000100_crew_files.sql). Null when
--                             nobody has drawn on it.
--   attachments.marked_at     When it was last drawn on.
--
-- The app shows the marked-up copy, with a way to see the original. An app from before this knows
-- only `path`, so it shows the original, and nothing it does can part the two: it never writes
-- marked_path, and deleting the row takes both (below).
--
--   Drawn on again       The new copy replaces the old one, which goes to the Trash (unlisted
--   or the drawing off   there as its own photo, kept 30 days like everything in it).
--   Photo removed        Both go to the Trash. Putting the photo back from the Trash brings its
--                        drawing back with it, while that's still there.
--   Original replaced    A new `path` (nothing in the app does this today) is a photo nobody drew
--                        on: the copy comes off, as OK to share does (attachment_share_guard).
--   Kept, not deleted    A marked-up copy is a file in use (private.stored_path_in_use), so the
--                        Trash's purge and the server's sweep of unrecorded files leave it alone.
--
-- Who can draw on a photo is who can change its row (attachments_update: the office, or whoever
-- added it); a sub can add one already drawn on, in their visit's folder, as they add photos.
--
-- supabase/tests/marked_up_photos_test.sql covers it.

alter table public.attachments
  add column marked_path text,
  add column marked_at timestamptz;
comment on column public.attachments.marked_path is 'The photo drawn on: a copy in the same folder, shown instead of the original';
comment on column public.attachments.marked_at is 'When the photo was last drawn on';
create index attachments_marked_path_idx on public.attachments (marked_path) where marked_path is not null;

-- The copy sits in the original's own folder, is never the original itself, and is dated as it's
-- set. A new original drops the copy.
create function private.attachment_markup_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.path is distinct from old.path and new.marked_path is not distinct from old.marked_path then
    new.marked_path := null;
  end if;
  if new.marked_path is not null and (tg_op = 'INSERT' or new.marked_path is distinct from old.marked_path) then
    if new.marked_path = new.path
       or not starts_with(new.marked_path, regexp_replace(new.path, '[^/]*$', ''))
       or position('/' in substr(new.marked_path, length(regexp_replace(new.path, '[^/]*$', '')) + 1)) > 0
       or new.marked_path ~ '(^|/)\.\.?(/|$)' then
      raise exception 'A photo''s drawing is stored beside the photo. Draw on it again.' using errcode = '22023';
    end if;
  end if;
  if tg_op = 'INSERT' or new.marked_path is distinct from old.marked_path then
    new.marked_at := case when new.marked_path is null then null else now() end;
  end if;
  return new;
end $$;
revoke all on function private.attachment_markup_guard() from public;
create trigger attachment_markup_guard before insert or update of path, marked_path on public.attachments
  for each row execute function private.attachment_markup_guard();

-- A drawing replaced, taken off, or gone with its photo: into the Trash, labelled as the photo's
-- drawing. Nothing to put it back on by itself (the photo coming back from the Trash brings it).
create function private.trash_photo_markup() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_label text;
begin
  if old.marked_path is null or (tg_op = 'UPDATE' and new.marked_path is not distinct from old.marked_path) then
    return null;
  end if;
  if not exists (select 1 from public.companies c where c.id = old.company_id) then
    return null;
  end if;
  if old.owner_type = 'quote' then
    select 'Quote photo · Quote #' || q.number into v_label from public.quotes q where q.id = old.owner_id;
  elsif old.owner_type = 'visit' then
    select 'Visit photo · ' || coalesce('Job #' || j.number, nullif(trim(v.title), ''), 'Visit') into v_label
    from public.visits v left join public.jobs j on j.id = v.job_id where v.id = old.owner_id;
  end if;
  perform private.trash_stored_file(old.company_id, old.marked_path,
    regexp_replace(old.file_name, '\.[A-Za-z0-9]{1,8}$', '') || ' (drawn on).jpg', 'image/jpeg', null,
    case when old.owner_type = 'quote' then 'quote_photo' else 'visit_photo' end, old.owner_id,
    coalesce(v_label, case when old.owner_type = 'visit' then 'Visit photo' else initcap(old.owner_type) || ' file' end) || ' (drawn on)',
    null, old.owner_type);
  return null;
end $$;
revoke all on function private.trash_photo_markup() from public;
create trigger trash_markup after delete on public.attachments
  for each row when (old.marked_path is not null) execute function private.trash_photo_markup();
create trigger trash_replaced_markup after update on public.attachments
  for each row when (old.marked_path is distinct from new.marked_path) execute function private.trash_photo_markup();

-- A photo put back from the Trash (drive_restore names the row's columns as they were, without
-- this one): its drawing comes back with it, out of the Trash, while that's still there.
create function private.restore_photo_markup() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_marked text;
begin
  if new.marked_path is not null or not private.trashing() then
    return new;
  end if;
  select t.restore ->> 'marked_path' into v_marked from public.trashed_files t
  where t.company_id = new.company_id and t.path = new.path;
  if v_marked is null then
    return new;
  end if;
  delete from public.trashed_files t where t.company_id = new.company_id and t.path = v_marked;
  if found then
    new.marked_path := v_marked;
  end if;
  return new;
end $$;
revoke all on function private.restore_photo_markup() from public;
-- Named to run before attachment_markup_guard, which checks and dates what this sets.
create trigger attachment_markup_back before insert on public.attachments
  for each row execute function private.restore_photo_markup();

-- As in 20261109000200_equipment_photos.sql, with a photo's drawing counted as in use.
create or replace function private.stored_path_in_use(p_company uuid, p_path text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_folder text := split_part(p_path, '/', 2);
  -- The applicant, channel or person whose folder it's in.
  v_owner uuid := case when split_part(p_path, '/', 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(p_path, '/', 3)::uuid end;
  v_file jsonb := jsonb_build_array(jsonb_build_object('path', p_path));
begin
  if exists (select 1 from public.plan_files f where f.path = p_path)
     or exists (select 1 from public.attachments a where a.path = p_path)
     or exists (select 1 from public.attachments a where a.marked_path = p_path)
     or exists (select 1 from public.sub_documents d where d.path = p_path)
     or exists (select 1 from public.expenses e where e.receipt_path = p_path)
     or exists (select 1 from public.sop_pages s where s.cover_path = p_path)
     or exists (select 1 from public.sop_categories c where c.cover_path = p_path)
     or exists (select 1 from private.sop_pictures g where g.path = p_path)
     or exists (select 1 from public.equipment e where e.photo_path = p_path)
     or exists (select 1 from public.equipment_photos p where p.path = p_path)
     or exists (select 1 from public.job_materials m where m.photo_path = p_path)
     or exists (select 1 from public.measurements m where m.snapshot_path = p_path) then
    return true;
  end if;
  return case v_folder
    -- An applicant's file is only ever on that applicant (applicant_files_guard).
    when 'applicants' then v_owner is not null
      and exists (select 1 from public.job_applicants a where a.id = v_owner and a.files @> v_file)
    -- A chat photo is only ever in its own channel's messages (chat_message_guard).
    when 'chat' then v_owner is not null
      and exists (select 1 from public.chat_messages m where m.channel_id = v_owner and m.attachments @> v_file)
    -- Pictures only the server stores, each in its own folder.
    when 'avatars' then v_owner is not null and exists (select 1 from public.profiles p where p.user_id = v_owner and p.avatar_url = p_path)
    when 'logo' then exists (select 1 from public.companies c where c.id = p_company and c.settings -> 'branding' ->> 'logo' = p_path)
    when 'packages' then exists (select 1 from public.roof_packages r where r.picture = p_path)
      or exists (select 1 from public.quote_options o where o.picture = p_path)
    when 'services' then exists (select 1 from public.services s where s.picture = p_path)
    else false
  end;
end $$;

-- 20261031000400_ok_to_share.sql, with each photo's drawing (marked_path) for the Photos card to
-- show. The same rows, read the same way, as the person asking.
drop function public.record_photos(uuid, uuid, uuid);
create function public.record_photos(p_company uuid, p_job uuid default null, p_client uuid default null)
returns table (
  id uuid, path text, file_name text, content_type text, created_at timestamptz, created_by uuid, shareable boolean, shareable_at timestamptz,
  owner_type text, job_id uuid, job_number bigint, job_title text, visit_id uuid, visit_on date, can_share boolean, cant_share text,
  marked_path text
)
language sql stable security invoker set search_path = '' as $$
  with found as (
    select a.* from public.attachments a
     where a.company_id = p_company and lower(coalesce(a.content_type, '')) like 'image/%'
       and (
         (p_job is not null and (
           (a.owner_type = 'job' and a.owner_id = p_job)
           or (a.owner_type = 'visit' and a.owner_id in (select v.id from public.visits v where v.company_id = p_company and v.job_id = p_job))
           or (a.owner_type = 'quote' and a.owner_id in (select j.quote_id from public.jobs j where j.company_id = p_company and j.id = p_job and j.quote_id is not null))))
         or (p_client is not null and p_job is null and private.attachment_client(p_company, a.owner_type, a.owner_id) = p_client)
       )
  )
  select f.id, f.path, f.file_name, f.content_type, f.created_at, f.created_by, f.shareable, f.shareable_at, f.owner_type,
         j.id, j.number, j.title, case when f.owner_type = 'visit' then f.owner_id end, v.scheduled_on,
         x.problem is null, x.problem, f.marked_path
    from found f
    left join public.visits v on f.owner_type = 'visit' and v.id = f.owner_id
    left join public.jobs j on j.id = private.attachment_job(p_company, f.owner_type, f.owner_id)
    cross join lateral (select private.photo_share_problem(p_company, f.owner_type, f.owner_id, f.content_type) as problem) x
   order by v.scheduled_on desc nulls last, f.created_at desc, f.id desc
   limit 500
$$;
revoke execute on function public.record_photos(uuid, uuid, uuid) from public, anon;
grant execute on function public.record_photos(uuid, uuid, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
