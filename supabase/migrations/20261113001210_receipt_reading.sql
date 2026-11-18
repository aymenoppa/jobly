-- Receipts and supplier invoices read by Claude, and several at once as drafts to confirm.
--
-- With the company's switch on (settings.receipt_reading, turned on by the server only once the
-- company's Claude key answers: apps/api/src/routes/receipts.ts), a photo or PDF added to an expense
-- is read and fills in the form, which the person checks and saves as before. Two things are new
-- on an expense for it:
--
--   expenses.tax_amount    the tax a receipt shows, included in amount (amount is still what it cost).
--   expenses.line_items    a supplier invoice's lines as read: [{description, quantity, unit,
--                          unit_price, amount}], kept with it for whoever looks at it later.
--
-- The office can also drop several receipts or supplier invoices at once. Each is uploaded to the
-- receipts/ folder as any receipt is, and becomes a draft:
--
--   expense_drafts         one file waiting to be confirmed as an expense: on a job or not yet, read
--                          or being read, with what was read (read) for the form to start from. A
--                          table of its own, not a kind of expense: nothing that reads expenses (the
--                          job page, Finance, Services, AI assistants, exports, the profit check, and
--                          the previous app still on phones for a while after this update) can count
--                          one by mistake. For the office with job costs, who see every expense.
--   save_read_expense()    saves the expense the person checked, and (if they chose) logs a supplier
--                          invoice's lines as the job's materials used, and removes its draft, all
--                          at once, as the person saving (row-level security applies). A job's lines
--                          are never changed.
--
-- A draft's file counts as in use (stored_path_in_use), so nothing tidies it away, and goes to the
-- Trash when the draft is discarded, as an expense's receipt does. Confirmed, it's the expense's.
--
-- supabase/tests/receipt_reading_test.sql covers it.

alter table public.expenses
  add column tax_amount numeric(12, 2) check (tax_amount >= 0),
  add column line_items jsonb check (line_items is null or jsonb_typeof(line_items) = 'array');
comment on column public.expenses.tax_amount is 'The tax the receipt shows, included in amount.';
comment on column public.expenses.line_items is 'A supplier invoice''s lines as read from it: [{description, quantity, unit, unit_price, amount}].';

create table public.expense_drafts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  job_id uuid,
  user_id uuid references auth.users (id) on delete set null default auth.uid(),
  receipt_path text not null check (length(receipt_path) between 1 and 500),
  file_name text check (length(file_name) <= 255),
  -- reading: sent to be read; read: read (what was found in `read`); failed: couldn't be (`error` says why).
  status text not null default 'reading' check (status in ('reading', 'read', 'failed')),
  read jsonb,
  error text check (length(error) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (company_id, id),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete set null (job_id)
);
comment on table public.expense_drafts is 'A receipt or supplier invoice dropped in with others, waiting for the office to confirm it as an expense (save_read_expense). Not an expense: nothing counts it.';
create index expense_drafts_company_idx on public.expense_drafts (company_id, created_at);
create index expense_drafts_job_idx on public.expense_drafts (job_id) where job_id is not null;
create index expense_drafts_receipt_path_idx on public.expense_drafts (receipt_path);

alter table public.expense_drafts enable row level security;
create policy expense_drafts_office on public.expense_drafts for all to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'job_costs'))
  with check (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'job_costs')
              and starts_with(receipt_path, company_id::text || '/receipts/') and receipt_path !~ '(^|/)\.\.?(/|$)');
revoke all on public.expense_drafts from anon;
revoke truncate on public.expense_drafts from authenticated;
create trigger touch_updated_at before update on public.expense_drafts for each row execute function private.touch_updated_at();

-- A draft's file follows it: who uploaded it, and its company, stay as they were.
create function private.expense_draft_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.company_id := old.company_id;
    new.receipt_path := old.receipt_path;
    new.user_id := old.user_id;
    new.created_at := old.created_at;
  else
    new.user_id := coalesce((select auth.uid()), new.user_id);
  end if;
  return new;
end $$;
create trigger guard before insert or update on public.expense_drafts for each row execute function private.expense_draft_guard();

-- Discarded, its file goes to the Trash as a removed receipt does (unless an expense has it now).
create function private.trash_draft_receipt() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.trash_stored_file(old.company_id, old.receipt_path,
    coalesce(nullif(trim(old.file_name), ''), 'Receipt' || private.file_ext(old.receipt_path)), null, null, 'receipt', old.id,
    concat_ws(' · ', 'Receipt', nullif(trim(old.read ->> 'vendor'), ''), (select 'Job #' || j.number from public.jobs j where j.id = old.job_id)), null);
  return null;
end $$;
create trigger trash_files after delete on public.expense_drafts for each row execute function private.trash_draft_receipt();
revoke all on function private.expense_draft_guard(), private.trash_draft_receipt() from public;

-- As in 20261109000200_equipment_photos.sql, plus expense_drafts.
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

/**
 * The expense the person checked (p_expense: company_id, job_id, vendor, description, category,
 * amount, tax_amount, incurred_on, receipt_path, reimbursable, in_line_costs, line_items), and, if
 * they chose, a supplier invoice's lines logged as the job's materials used (p_materials:
 * [{service_id, name, unit, quantity, ticket}]), and its draft removed (p_draft). All or nothing, as
 * the person saving: what they can't do on their own, this doesn't do either. Returns the expense.
 */
create function public.save_read_expense(p_expense jsonb, p_materials jsonb default '[]', p_draft uuid default null) returns uuid
language plpgsql set search_path = '' as $$
declare
  e public.expenses := jsonb_populate_record(null::public.expenses, p_expense);
  v_id uuid;
  v_count integer;
begin
  if jsonb_typeof(coalesce(p_materials, '[]')) <> 'array' then
    raise exception 'Materials are a list.' using errcode = '22023';
  end if;
  insert into public.expenses (company_id, job_id, vendor, description, category, amount, tax_amount, incurred_on, receipt_path, reimbursable, in_line_costs, line_items)
  values (e.company_id, e.job_id, e.vendor, e.description, e.category, e.amount, e.tax_amount, coalesce(e.incurred_on, current_date), e.receipt_path,
          coalesce(e.reimbursable, false), coalesce(e.in_line_costs, false), e.line_items)
  returning id into v_id;
  if jsonb_array_length(coalesce(p_materials, '[]')) > 0 then
    if e.job_id is null then
      raise exception 'Pick the job to log the materials on.' using errcode = '22023';
    end if;
    insert into public.job_materials (company_id, job_id, service_id, name, quantity, unit, supplier, ticket, notes)
    select e.company_id, e.job_id, m.service_id, left(trim(m.name), 200), m.quantity, left(coalesce(nullif(trim(m.unit), ''), 'ea'), 20),
           left(nullif(trim(e.vendor), ''), 120), left(nullif(trim(m.ticket), ''), 60), 'From a supplier invoice'
    from jsonb_to_recordset(p_materials) as m(service_id uuid, name text, unit text, quantity numeric, ticket text);
  end if;
  if p_draft is not null then
    delete from public.expense_drafts d where d.id = p_draft and d.company_id = e.company_id;
    get diagnostics v_count = row_count;
    if v_count = 0 then
      raise exception 'This draft is gone: someone may have saved or discarded it already.' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end $$;
revoke execute on function public.save_read_expense(jsonb, jsonb, uuid) from public, anon;
grant execute on function public.save_read_expense(jsonb, jsonb, uuid) to authenticated;

-- Its policies look the person's roles up once a query, not once a row (20261018000990_policy_lookups.sql).
select private.fold_member_checks('public.expense_drafts');

notify pgrst, 'reload schema';
