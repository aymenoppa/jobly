-- Small preview copies of pictures in Plans and files and Drive.
--
-- A picture's preview on a list (Plans and files, a crew's visit, Drive) loaded the whole picture,
-- up to 10 MB. Now, when a picture is added from the browser, the browser also stores a copy about
-- 320 pixels on its long side (WebP, or JPEG where the browser can't make WebP), and the lists show
-- that. Files with none (older files, Google Drive imports, files sent through booking forms, a
-- copy that couldn't be made) show as before.
--
--   plan_files.preview_path   the copy, stored next to the file: <company>/plans/<uuid>.preview.webp
--                             (or .jpg) for the file at <company>/plans/<uuid>.<ext>. Only ever that
--                             name, so a row can't name another file's stored file as its copy, and no
--                             file's own path can be a copy's. Set when the row is added, never changed.
--   storage.objects           a copy is read by exactly the people who can read its file: files_read
--                             and files_sub_read let a plans/ file be read through a row that names it
--                             as its path or as its copy, and row-level security on plan_files decides
--                             which rows those are. Crews never get an office-only file's copy.
--   upkeep                    the copy goes with its file: trash_purge and trash_delete_forever hand
--                             over both, stored_path_in_use counts a copy as in use while its row is
--                             there, and the nightly sweep of plan files nobody recorded
--                             (apps/api/src/services/planFiles.ts, tidyPlanFiles) keeps a copy its row
--                             names and removes one with no row once it's a day old.
--   Drive's lists             drive_list and drive_versions return it.
--
-- supabase/tests/plan_previews_test.sql covers it.

alter table public.plan_files add column preview_path text;
alter table public.plan_files add constraint plan_files_preview_path check (
  preview_path is null or preview_path in (
    regexp_replace(path, '\.[a-z0-9]{1,8}$', '.preview.webp'),
    regexp_replace(path, '\.[a-z0-9]{1,8}$', '.preview.jpg')
  )
);
-- Looked up for each stored file read (files_read), and by the sweep and the purge.
create unique index plan_files_preview_idx on public.plan_files (preview_path) where preview_path is not null;

comment on column public.plan_files.preview_path is 'A small copy of a picture for lists (<company>/plans/<uuid>.preview.webp or .jpg, next to path). Read by whoever can read the file.';

-- What a file is and where its history goes don't change by hand, its copy included. As
-- 20261028000300_drive.sql otherwise.
create or replace function private.plan_files_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.company_id := old.company_id;
  new.path := old.path;
  new.preview_path := old.preview_path;
  new.file_name := old.file_name;
  new.content_type := old.content_type;
  new.size_bytes := old.size_bytes;
  new.created_by := old.created_by;
  new.created_at := old.created_at;
  if pg_trigger_depth() <= 1 and not private.trashing() then
    new.replaces_id := old.replaces_id;
    new.superseded_at := old.superseded_at;
    new.deleted_at := old.deleted_at;
    new.deleted_by := old.deleted_by;
    new.trashed_from := old.trashed_from;
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Who reads a copy: whoever reads its file
-- ---------------------------------------------------------------------------------------------

-- As 20261112000100_crew_files.sql, with a plan file's copy read through its row as its file is.
drop policy files_read on storage.objects;
create policy files_read on storage.objects for select to authenticated using (
  bucket_id = 'files' and private.is_member(private.path_company(name)) and (
    -- The office, as before (20261028000100_careers.sql).
    (private.has_role(private.path_company(name), '{owner,admin,office,estimator}')
      and split_part(name, '/', 2) not in ('receipts', 'chat', 'subs', 'applicants'))
    -- Everyone on the team.
    or split_part(name, '/', 2) in ('avatars', 'equipment', 'kb', 'logo')
    or (split_part(name, '/', 2) = 'visit' and exists (
      select 1 from public.visits v where v.id = private.path_record(objects.name) and v.company_id = private.path_company(objects.name)))
    or (split_part(name, '/', 2) in ('job', 'tickets') and exists (
      select 1 from public.jobs j where j.id = private.path_record(objects.name) and j.company_id = private.path_company(objects.name)))
    or (split_part(name, '/', 2) = 'quote' and exists (
      select 1 from public.jobs j where j.quote_id = private.path_record(objects.name) and j.company_id = private.path_company(objects.name)))
    or (split_part(name, '/', 2) = 'property' and exists (
      select 1 from public.properties p where p.id = private.path_record(objects.name) and p.company_id = private.path_company(objects.name)))
    or (split_part(name, '/', 2) = 'request' and exists (
      select 1 from public.requests r where r.id = private.path_record(objects.name) and r.company_id = private.path_company(objects.name)))
    or (split_part(name, '/', 2) = 'client' and exists (
      select 1 from public.clients c where c.id = private.path_record(objects.name) and c.company_id = private.path_company(objects.name)))
    or (split_part(name, '/', 2) = 'property-equipment' and exists (select 1 from public.property_assets a where a.photo_path = objects.name))
    -- A plan file, or its preview copy, through a row they can see.
    or (split_part(name, '/', 2) = 'plans' and exists (
      select 1 from public.plan_files f where f.path = objects.name or f.preview_path = objects.name))
    or (split_part(name, '/', 2) = 'measurements' and private.has_role(private.path_company(name), '{crew_lead}'))
    -- Their own: stored by them, or put in the Trash by them. A plan follows its row whoever stored it.
    or (split_part(name, '/', 2) not in ('plans', 'receipts', 'chat', 'subs', 'applicants')
      and (owner = (select auth.uid()) or private.trashed_by_me(name)))
    -- The four with rules of their own, as before.
    or (split_part(name, '/', 2) = 'receipts' and (owner = (select auth.uid()) or private.has_perm(private.path_company(name), 'job_costs')))
    or (split_part(name, '/', 2) = 'chat' and private.chat_can(private.chat_file_channel(name), 'see'))
    or (split_part(name, '/', 2) = 'subs' and private.has_role(private.path_company(name), '{owner,admin,office}') and private.has_perm(private.path_company(name), 'subs'))
    or (split_part(name, '/', 2) = 'applicants' and private.has_role(private.path_company(name), '{owner,admin,office}') and private.has_perm(private.path_company(name), 'hiring'))
  )
);

-- Subcontractors: as 20261025002003_sub_field_app.sql, with a plan's copy read through its row too.
drop policy files_sub_read on storage.objects;
create policy files_sub_read on storage.objects for select to authenticated using (
  bucket_id = 'files' and private.path_company(name) = any ((select private.sub_companies())::uuid[]) and (
    (split_part(name, '/', 2) = 'visit'
      and (private.path_company(name), split_part(name, '/', 3)) in (select v.company_id, v.visit_id::text from private.my_sub_visits() v))
    or (split_part(name, '/', 2) = 'subs'
      and (private.path_company(name), split_part(name, '/', 3)) in (select s.company_id, s.subcontractor_id::text from private.my_subs() s))
    or (split_part(name, '/', 2) = 'avatars' and split_part(name, '/', 3) = (select auth.uid())::text)
    or (split_part(name, '/', 2) = 'plans' and exists (
      select 1 from public.plan_files f where f.path = objects.name or f.preview_path = objects.name))
  )
);

-- ---------------------------------------------------------------------------------------------
-- A copy goes with its file
-- ---------------------------------------------------------------------------------------------

-- A plan file's copy is in use while its row is there, as its file is. As
-- 20261113001220_files_in_use_both.sql otherwise.
create or replace function private.stored_path_in_use(p_company uuid, p_path text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_folder text := split_part(p_path, '/', 2);
  -- The applicant, channel or person whose folder it's in.
  v_owner uuid := case when split_part(p_path, '/', 3) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then split_part(p_path, '/', 3)::uuid end;
  v_file jsonb := jsonb_build_array(jsonb_build_object('path', p_path));
begin
  if exists (select 1 from public.plan_files f where f.path = p_path)
     or exists (select 1 from public.plan_files f where f.preview_path = p_path)
     or exists (select 1 from public.attachments a where a.path = p_path)
     or exists (select 1 from public.attachments a where a.marked_path = p_path)
     or exists (select 1 from public.sub_documents d where d.path = p_path)
     or exists (select 1 from public.expenses e where e.receipt_path = p_path)
     or exists (select 1 from public.expense_drafts d where d.receipt_path = p_path)
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
revoke all on function private.stored_path_in_use(uuid, text) from public;

/**
 * The nightly purge, as 20261028000300_drive.sql: a plan file deleted for good hands over its
 * preview copy too. `deleted` still counts rows.
 */
create or replace function public.trash_purge(p_cutoff timestamptz, p_limit integer default 1000)
returns table (source text, company_id uuid, deleted integer, paths text[])
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_cutoff timestamptz := least(coalesce(p_cutoff, '-infinity'), now() - interval '30 days');
  v_limit integer := least(greatest(coalesce(p_limit, 1000), 1), 5000);
  -- Companies at a time (a row each from each of the three).
  v_firms constant integer := 300;
  v_companies uuid[];
  v_paths text[];
  -- Each deleted plan file's copy, beside its path (null for none).
  v_previews text[];
begin
  with due as (
    select distinct f.company_id, f.deleted_at from public.plan_files f
    where f.deleted_at < v_cutoff
    order by f.deleted_at
    limit v_limit
  ), firms as (
    select d.company_id from due d group by d.company_id order by min(d.deleted_at) limit v_firms
  ), gone as (
    delete from public.plan_files f using due m
    where f.company_id = m.company_id and f.deleted_at = m.deleted_at and f.deleted_at < v_cutoff
      and m.company_id in (select firms.company_id from firms)
    returning f.company_id, f.path, f.preview_path
  )
  select coalesce(array_agg(gone.company_id), '{}'), coalesce(array_agg(gone.path), '{}'), coalesce(array_agg(gone.preview_path), '{}')
  into v_companies, v_paths, v_previews from gone;
  return query
  select 'plan_files'::text, x.c, count(*)::integer,
    coalesce(array_agg(x.p) filter (where not private.stored_path_in_use(x.c, x.p)), '{}')
      || coalesce(array_agg(x.v) filter (where x.v is not null and not private.stored_path_in_use(x.c, x.v)), '{}')
  from unnest(v_companies, v_paths, v_previews) as x(c, p, v)
  group by x.c;

  with picked as (
    select d.id, d.company_id, d.deleted_at from public.drive_folders d
    where d.deleted_at < v_cutoff and not private.drive_folder_holds_live(d.id)
    order by d.deleted_at
    limit v_limit
  ), firms as (
    select p.company_id from picked p group by p.company_id order by min(p.deleted_at) limit v_firms
  ), gone as (
    delete from public.drive_folders d using picked p
    where d.id = p.id and d.deleted_at < v_cutoff and p.company_id in (select firms.company_id from firms)
    returning d.company_id
  )
  select coalesce(array_agg(gone.company_id), '{}') into v_companies from gone;
  return query
  select 'drive_folders'::text, x.c, count(*)::integer, '{}'::text[]
  from unnest(v_companies) as x(c)
  group by x.c;

  with picked as (
    select t.id, t.company_id, t.deleted_at from public.trashed_files t
    where t.deleted_at < v_cutoff
    order by t.deleted_at
    limit v_limit
  ), firms as (
    select p.company_id from picked p group by p.company_id order by min(p.deleted_at) limit v_firms
  ), gone as (
    delete from public.trashed_files t using picked p
    where t.id = p.id and t.deleted_at < v_cutoff and p.company_id in (select firms.company_id from firms)
    returning t.company_id, t.path
  )
  select coalesce(array_agg(gone.company_id), '{}'), coalesce(array_agg(gone.path), '{}') into v_companies, v_paths from gone;
  return query
  select 'trashed_files'::text, x.c, count(*)::integer, coalesce(array_agg(x.p) filter (where not private.stored_path_in_use(x.c, x.p)), '{}')
  from unnest(v_companies, v_paths) as x(c, p)
  group by x.c;
end $$;

/**
 * Delete forever, as 20261028000300_drive.sql: a plan file deleted for good hands over its preview
 * copy too.
 */
create or replace function public.trash_delete_forever(p_company uuid, p_items jsonb)
returns table (kind text, id uuid, paths text[])
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_item record;
  v_at timestamptz;
  v_tree uuid[];
  v_paths text[];
  v_count integer;
  t public.trashed_files;
begin
  if not private.has_role(p_company, '{owner}') then
    raise exception 'Only owners can delete things for good.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) > 200 then
    raise exception 'Choose up to 200 things to delete at a time.' using errcode = '22023';
  end if;
  for v_item in
    select distinct e ->> 'kind' as kind, (e ->> 'id')::uuid as id
    from jsonb_array_elements(p_items) e
    where jsonb_typeof(e) = 'object' and e ->> 'kind' in ('file', 'version', 'folder', 'other')
      and e ->> 'id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  loop
    v_paths := null;
    v_count := 0;
    if v_item.kind in ('file', 'version') then
      -- Held, as drive_restore holds it, so the two go one after the other.
      select f.deleted_at into v_at from public.plan_files f
      where f.id = v_item.id and f.company_id = p_company and f.deleted_at is not null
      for update;
      continue when not found;
      with gone as (
        delete from public.plan_files f
        where f.id in (select private.drive_chain(v_item.id)) and f.company_id = p_company and f.deleted_at = v_at
        returning f.path, f.preview_path
      )
      select array_agg(gone.path) || array_remove(array_agg(gone.preview_path), null) into v_paths from gone;
      continue when v_paths is null;
    elsif v_item.kind = 'folder' then
      select d.deleted_at into v_at from public.drive_folders d
      where d.id = v_item.id and d.company_id = p_company and d.deleted_at is not null
      for update;
      continue when not found;
      v_tree := array(
        with recursive tree as (
          select v_item.id as id
          union
          select c.id from public.drive_folders c join tree x on c.parent_id = x.id where c.deleted_at = v_at
        )
        select tree.id from tree
      );
      if private.drive_folder_holds_live(v_item.id) then
        raise exception 'A folder in the Trash still has a folder in use inside it. Restore it and move that folder out first.' using errcode = '22023';
      end if;
      with gone as (
        delete from public.plan_files f
        where f.company_id = p_company and f.deleted_at = v_at and f.id in (
          with recursive chain as (
            select x.id, x.replaces_id from public.plan_files x where x.company_id = p_company and x.deleted_at = v_at and x.folder_id = any (v_tree)
            union
            select x.id, x.replaces_id from public.plan_files x join chain c on x.replaces_id = c.id or x.id = c.replaces_id
            where x.company_id = p_company and x.deleted_at = v_at
          )
          select chain.id from chain
        )
        returning f.path, f.preview_path
      )
      select array_agg(gone.path) || array_remove(array_agg(gone.preview_path), null) into v_paths from gone;
      delete from public.drive_folders d where d.id = any (v_tree) and d.company_id = p_company and d.deleted_at = v_at;
      get diagnostics v_count = row_count;
      continue when v_count = 0;
    else
      select * into t from public.trashed_files x where x.id = v_item.id and x.company_id = p_company for update;
      continue when not found or not private.trashed_file_visible(t);
      delete from public.trashed_files x where x.id = t.id;
      v_paths := array[t.path];
    end if;
    return query
    select v_item.kind, v_item.id, coalesce(array_agg(x.p) filter (where x.p is not null and not private.stored_path_in_use(p_company, x.p)), '{}')
    from unnest(coalesce(v_paths, '{}')) as x(p);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Drive's lists
-- ---------------------------------------------------------------------------------------------

-- As 20261028000300_drive.sql, with each file's copy.
create or replace view private.drive_files with (security_invoker = true) as
select
  f.company_id, f.id, f.title, f.file_name, f.content_type, f.size_bytes, f.path, f.revision, f.notes,
  f.crew_visible, f.archived, f.replaces_id, f.superseded_at, private.drive_version_count(f.id) as versions,
  f.folder_id, fo.name as folder_name,
  f.property_id, coalesce(nullif(trim(p.line1), ''), nullif(trim(p.label), '')) as property_label,
  cl.id as client_id, cl.display_name as client_name,
  f.request_id, r.title as request_title,
  f.quote_id, q.number as quote_number, q.title as quote_title,
  f.job_id, j.number as job_number, j.title as job_title,
  f.created_by, nullif(trim(pr.full_name), '') as created_by_name, f.created_at, f.updated_at,
  f.preview_path
from public.plan_files f
left join public.drive_folders fo on fo.id = f.folder_id
left join public.properties p on p.id = f.property_id
left join public.requests r on r.id = f.request_id
left join public.quotes q on q.id = f.quote_id
left join public.jobs j on j.id = f.job_id
left join public.clients cl on cl.id = coalesce(j.client_id, q.client_id, r.client_id, p.client_id)
left join public.profiles pr on pr.user_id = f.created_by
where f.deleted_at is null;

-- What they return changes, so they're made again: as 20261028000300_drive.sql, with preview_path last.
drop function public.drive_list(uuid, text, uuid, text, integer);
create function public.drive_list(p_company uuid, p_scope text, p_id uuid default null, p_query text default null, p_limit integer default 200)
returns table (id uuid, title text, file_name text, content_type text, size_bytes bigint, path text, revision text, notes text,
  crew_visible boolean, archived boolean, replaces_id uuid, versions integer, folder_id uuid, folder_name text,
  property_id uuid, property_label text, client_id uuid, client_name text, request_id uuid, request_title text,
  quote_id uuid, quote_number bigint, quote_title text, job_id uuid, job_number bigint, job_title text,
  created_by uuid, created_by_name text, created_at timestamptz, updated_at timestamptz, preview_path text)
language plpgsql stable security invoker set search_path = '' as $$
#variable_conflict use_column
declare
  v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
  v_q text := trim(coalesce(p_query, ''));
  v_like text;
  v_num bigint;
  v_folder uuid := p_id;
begin
  if p_scope is null or p_scope not in ('folder', 'client', 'recent', 'search') then
    raise exception 'Choose the folder, client, recent or search list.' using errcode = '22023';
  end if;
  if not private.is_member(p_company) or (p_scope = 'client' and p_id is null) or (p_scope = 'search' and length(v_q) = 0) then
    return;
  end if;
  if p_scope = 'folder' and v_folder is null then
    select d.id into v_folder from public.drive_folders d where d.company_id = p_company and d.parent_id is null;
  end if;
  if p_scope = 'search' then
    v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    if v_q ~ '^#?[0-9]{1,12}$' then
      v_num := ltrim(v_q, '#')::bigint;
    end if;
  end if;
  return query
  select r.id, r.title, r.file_name, r.content_type, r.size_bytes, r.path, r.revision, r.notes,
    r.crew_visible, r.archived, r.replaces_id, r.versions, r.folder_id, r.folder_name,
    r.property_id, r.property_label, r.client_id, r.client_name, r.request_id, r.request_title,
    r.quote_id, r.quote_number, r.quote_title, r.job_id, r.job_number, r.job_title,
    r.created_by, r.created_by_name, r.created_at, r.updated_at, r.preview_path
  from private.drive_files r
  where r.company_id = p_company and r.superseded_at is null
    and case p_scope
      when 'folder' then r.folder_id = v_folder
      when 'client' then r.client_id = p_id
      when 'recent' then true
      else r.title ilike v_like or r.file_name ilike v_like or r.revision ilike v_like or r.notes ilike v_like
        or r.client_name ilike v_like or r.job_title ilike v_like or r.job_number = v_num or r.quote_number = v_num
    end
  order by case when p_scope in ('folder', 'client') then lower(r.title) end, r.created_at desc, r.id
  limit v_limit;
end $$;

drop function public.drive_versions(uuid);
create function public.drive_versions(p_file uuid)
returns table (id uuid, title text, file_name text, content_type text, size_bytes bigint, path text, revision text, notes text,
  crew_visible boolean, archived boolean, replaces_id uuid, versions integer, folder_id uuid, folder_name text,
  property_id uuid, property_label text, client_id uuid, client_name text, request_id uuid, request_title text,
  quote_id uuid, quote_number bigint, quote_title text, job_id uuid, job_number bigint, job_title text,
  created_by uuid, created_by_name text, created_at timestamptz, updated_at timestamptz, preview_path text)
language plpgsql stable security invoker set search_path = '' as $$
#variable_conflict use_column
begin
  return query
  with recursive chain as (
    select f.id, f.replaces_id from public.plan_files f where f.id = p_file
    union
    select f.id, f.replaces_id from public.plan_files f join chain c on f.replaces_id = c.id or f.id = c.replaces_id
  )
  select r.id, r.title, r.file_name, r.content_type, r.size_bytes, r.path, r.revision, r.notes,
    r.crew_visible, r.archived, r.replaces_id, r.versions, r.folder_id, r.folder_name,
    r.property_id, r.property_label, r.client_id, r.client_name, r.request_id, r.request_title,
    r.quote_id, r.quote_number, r.quote_title, r.job_id, r.job_number, r.job_title,
    r.created_by, r.created_by_name, r.created_at, r.updated_at, r.preview_path
  from private.drive_files r
  where r.id in (select chain.id from chain) and r.company_id = any ((select private.member_companies())::uuid[])
  order by r.created_at desc, r.id;
end $$;

revoke execute on function public.drive_list(uuid, text, uuid, text, integer), public.drive_versions(uuid) from public, anon;
grant execute on function public.drive_list(uuid, text, uuid, text, integer), public.drive_versions(uuid) to authenticated;

-- The policies above check membership the per-row way; rewrite them like the others (see
-- 20261018000990_policy_lookups.sql).
select private.fold_member_checks('storage.objects');

notify pgrst, 'reload schema';
