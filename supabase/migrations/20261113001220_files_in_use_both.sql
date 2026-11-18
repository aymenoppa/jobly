-- A file is in use if a photo's drawing is it, or a receipt waiting to be confirmed is it.
--
-- Two changes on this branch each redefined private.stored_path_in_use from the same older copy:
-- 20261113001010_marked_up_photos.sql added photos' drawings (attachments.marked_path) and
-- 20261113001210_receipt_reading.sql added receipts waiting to be confirmed (expense_drafts). The
-- later one, run last, left the drawings out, so the Trash purge and the sweep of unrecorded files
-- could have taken a photo's drawing. This is that function with both.
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
