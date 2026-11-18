-- Keeping what files cost in hand, without anyone having to think in GB:
--
-- 1. A storage limit in dollars (Settings → Storage, on Railway). An owner or admin can say what
--    photos and files may cost a month ("Files can cost up to $10 a month") instead of a size. It's
--    kept as settings.storage.limit_dollars, and the limit in bytes is worked out from it whenever
--    it's read, at the price of where files are now: settings.storage.price_per_gb ($0.15 a GB-month
--    on the storage service's volume, $0.015 in a Railway bucket), never past settings.storage.cap_bytes
--    (90% of the volume, so it never fills; in a bucket, what Railway's plan lets a bucket hold).
--    The server keeps those two up to date from Railway (storage_set_rate, from
--    apps/api/src/services/storageUsage.ts), so when files move between the volume and a bucket the
--    dollars stay as they were and the size follows. Nothing else changes: the gateway's check
--    (storage_snapshot) and the overview (storage_overview) read the limit through
--    private.storage_company_limit as before. A limit in GB, the default and no limit are as they
--    were, and a company's limit stays whatever it was until someone chooses again. The same sum is
--    packages/core/src/storage.ts storageLimitFromDollars, for the page.
--
-- 2. settings.files (photos made smaller as they're added, and who may add videos to Drive and plan
--    files and how big: packages/core/src/storage.ts fileSettings) is decided in Settings → Storage,
--    so like the weather rules it stays as it was when someone without the settings area saves the
--    company. The server holds uploads to the video rules (apps/api/src/lib/storageLimits.ts).
--
-- 3. rate_limit_spend: a rate limit that counts an amount rather than one attempt, for what a public
--    link may send in a day (apps/api/src/lib/linkBudget.ts: a shared guide's or a showcase's
--    pictures, a quote's map drawings), so one link opened over and over can't run up the bill.
--
-- 4. A plan file's small preview copy (20261118000100_plan_previews.sql) counts with its file: in the
--    Trash when the file is, and toward whoever added it (storage_overview, storage_snapshot).
--
-- supabase/tests/storage_cost_limits_test.sql covers all four.

-- ---------------------------------------------------------------------------------------------
-- A limit in dollars
-- ---------------------------------------------------------------------------------------------

-- A dollar amount kept in settings, or null when it isn't a number above 0.
create function private.storage_dollars(p_value jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(p_value) = 'number' and (p_value #>> '{}')::numeric > 0 then (p_value #>> '{}')::numeric end
$$;

-- What p_dollars a month allows at p_price a GB-month, no more than p_cap (null: no cap). Null
-- when the price isn't known.
create function private.storage_from_dollars(p_dollars numeric, p_price numeric, p_cap bigint) returns bigint
language sql immutable set search_path = '' as $$
  select case when p_dollars > 0 and p_price > 0 then
    least(greatest(1, floor(p_dollars / p_price * 1000000000)), coalesce(p_cap, 9223372036854775807), 9223372036854775807)::bigint
  end
$$;

-- The company's limit as chosen: 'default' (limit_bytes left out), 'none' (null), 'custom' (a size)
-- or 'dollars' (limit_dollars, a monthly amount).
create or replace function private.storage_limit_mode(p_storage jsonb) returns text
language sql immutable set search_path = '' as $$
  select case when private.storage_dollars(p_storage -> 'limit_dollars') is not null then 'dollars'
    when not coalesce(p_storage ? 'limit_bytes', false) then 'default'
    when private.storage_bytes(p_storage -> 'limit_bytes') is null then 'none'
    else 'custom' end
$$;

-- The company's limit in bytes: its own, what its monthly amount buys where files are now, the
-- default, or null for none.
create or replace function private.storage_company_limit(p_storage jsonb) returns bigint
language sql immutable set search_path = '' as $$
  select case private.storage_limit_mode(p_storage)
    when 'custom' then private.storage_bytes(p_storage -> 'limit_bytes')
    when 'dollars' then private.storage_from_dollars(private.storage_dollars(p_storage -> 'limit_dollars'),
      private.storage_dollars(p_storage -> 'price_per_gb'), private.storage_bytes(p_storage -> 'cap_bytes'))
    when 'default' then private.storage_bytes(p_storage -> 'default_bytes')
  end
$$;

-- As before (20261028000400_storage_limits.sql), with the monthly amount kept like the size: the
-- server's own writes go through, but never to the limit itself.
create or replace function private.storage_settings_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_kept jsonb;
begin
  if private.storage_setting() or new.settings -> 'storage' is not distinct from old.settings -> 'storage' then
    return new;
  end if;
  if (select auth.uid()) is not null then
    v_kept := old.settings -> 'storage';
  else
    v_kept := (private.storage_of(new.settings) - array['limit_bytes', 'limit_dollars', 'changed_at', 'changed_by'])
      || coalesce((select jsonb_object_agg(e.key, e.value) from jsonb_each(private.storage_of(old.settings)) e
                   where e.key in ('limit_bytes', 'limit_dollars', 'changed_at', 'changed_by')), '{}');
    if v_kept = '{}' and old.settings -> 'storage' is null then
      v_kept := null;
    end if;
  end if;
  new.settings := case when v_kept is null then coalesce(new.settings, '{}') - 'storage'
    else jsonb_set(coalesce(new.settings, '{}'), '{storage}', v_kept) end;
  return new;
end $$;

drop function public.storage_set_limit(uuid, text, bigint);

/**
 * Settings → Storage: the company's limit. p_mode 'default' goes back to the default (the server's,
 * from Railway), 'none' takes the limit off, 'custom' sets p_limit_bytes, and 'dollars' sets what
 * files may cost a month, p_limit_dollars (to the cent), which needs the price of where files are
 * kept (Railway's, from the server). Owners and admins who manage settings. Returns
 * settings.storage as it is now.
 */
create function public.storage_set_limit(p_company uuid, p_mode text, p_limit_bytes bigint default null, p_limit_dollars numeric default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_limit jsonb;
  v_storage jsonb;
begin
  if not (private.has_role(p_company, '{owner,admin}') and private.has_perm(p_company, 'settings')) then
    raise exception 'Only owners and admins who manage settings can change the storage limit.' using errcode = '42501';
  end if;
  if p_mode is null or p_mode not in ('default', 'none', 'custom', 'dollars') then
    raise exception 'Choose the default limit, no limit, or a limit of your own.' using errcode = '22023';
  end if;
  if p_mode = 'custom' then
    if p_limit_bytes is null or p_limit_bytes <= 0 then
      raise exception 'A limit of your own needs a size of more than 0 GB.' using errcode = '22023';
    end if;
    if p_limit_bytes > 10000000000000000 then
      raise exception 'A limit can be 10,000,000 GB at most.' using errcode = '22023';
    end if;
  end if;
  if p_mode = 'dollars' then
    if p_limit_dollars is null or round(p_limit_dollars, 2) <= 0 then
      raise exception 'Enter what files may cost a month, more than $0.' using errcode = '22023';
    end if;
    if p_limit_dollars > 100000 then
      raise exception 'A monthly amount can be $100,000 at most.' using errcode = '22023';
    end if;
    if (select private.storage_dollars(private.storage_of(c.settings) -> 'price_per_gb') from public.companies c where c.id = p_company) is null then
      raise exception 'Jobly doesn''t know yet what Railway charges where your files are. Open Settings → Hosting, then try again.' using errcode = '22023';
    end if;
  end if;
  v_limit := case p_mode when 'custom' then jsonb_build_object('limit_bytes', p_limit_bytes)
    when 'none' then jsonb_build_object('limit_bytes', null)
    when 'dollars' then jsonb_build_object('limit_dollars', round(p_limit_dollars, 2))
    else '{}'::jsonb end;

  perform set_config('jobly.storage', 'on', true);
  update public.companies c
  set settings = jsonb_set(c.settings, '{storage}', (private.storage_of(c.settings) - array['limit_bytes', 'limit_dollars']) || v_limit
    || jsonb_build_object('changed_at', now(), 'changed_by', (select auth.uid())))
  where c.id = p_company
  returning c.settings -> 'storage' into v_storage;
  perform set_config('jobly.storage', 'off', true);
  return v_storage;
end $$;

/**
 * What a GB costs a month where the company's files are now (p_price_per_gb, in dollars) and the
 * most a monthly amount may buy there (p_cap_bytes; null for no cap): the server's, when it reads
 * Railway (apps/api/src/services/storageUsage.ts). A price that isn't known isn't sent, so a limit in
 * dollars keeps the last one rather than going away. Changes nothing when they're the same. The
 * server's alone.
 */
create function public.storage_set_rate(p_company uuid, p_price_per_gb numeric, p_cap_bytes bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_price_per_gb is null or p_price_per_gb <= 0 then
    raise exception 'A price is more than $0 a GB.' using errcode = '22023';
  end if;
  if p_cap_bytes is not null and p_cap_bytes <= 0 then
    raise exception 'A cap is more than 0 bytes, or null when there isn''t one.' using errcode = '22023';
  end if;
  perform set_config('jobly.storage', 'on', true);
  update public.companies c
  set settings = jsonb_set(c.settings, '{storage}', private.storage_of(c.settings)
    || jsonb_build_object('price_per_gb', p_price_per_gb, 'cap_bytes', p_cap_bytes))
  where c.id = p_company
    and jsonb_build_object('price_per_gb', private.storage_of(c.settings) -> 'price_per_gb', 'cap_bytes', private.storage_of(c.settings) -> 'cap_bytes')
      is distinct from jsonb_build_object('price_per_gb', p_price_per_gb, 'cap_bytes', p_cap_bytes);
  perform set_config('jobly.storage', 'off', true);
end $$;

-- ---------------------------------------------------------------------------------------------
-- settings.files is the settings area's
-- ---------------------------------------------------------------------------------------------

-- As 20261113000100_snow_app.sql (its latest), with settings.files under the settings area too.
create or replace function private.company_settings_area_guard() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_gate record;
  v_key text;
begin
  if (select auth.uid()) is null or new.settings is not distinct from old.settings then
    return new;
  end if;
  for v_gate in
    select * from (values
      ('apps', array['careers', 'drive', 'paving_app', 'roofing_app', 'snow_app', 'team_chat', 'website_analytics', 'website_forms']),
      ('settings', array['weather_rules', 'weather_source', 'files']),
      ('subs', array['subs'])) g(area, keys)
  loop
    continue when private.has_perm(new.id, v_gate.area);
    foreach v_key in array v_gate.keys loop
      if new.settings -> v_key is distinct from old.settings -> v_key then
        new.settings := case when old.settings -> v_key is null then coalesce(new.settings, '{}') - v_key
          else jsonb_set(coalesce(new.settings, '{}'), array[v_key], old.settings -> v_key) end;
      end if;
    end loop;
  end loop;
  return new;
end $$;

-- ---------------------------------------------------------------------------------------------
-- A rate limit by amount
-- ---------------------------------------------------------------------------------------------

/**
 * Counts p_amount (say, kilobytes sent) for p_key, as rate_limit_hit counts one attempt
 * (20261017002000_rate_limits.sql): false once more than p_max has been counted within
 * p_window_seconds, and from then until the window is over. The server's alone.
 */
create function public.rate_limit_spend(p_key text, p_amount integer, p_max integer, p_window_seconds integer) returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_spent integer;
begin
  if p_key is null or length(p_key) not between 1 and 200 then
    raise exception 'A rate limit key is 1 to 200 characters.' using errcode = '22023';
  end if;
  if p_max is null or p_max < 1 or p_max > 2000000000 then
    raise exception 'A rate limit allows 1 to 2,000,000,000.' using errcode = '22023';
  end if;
  if p_amount is null or p_amount < 0 then
    raise exception 'An amount is 0 or more.' using errcode = '22023';
  end if;
  if p_window_seconds is null or p_window_seconds not between 1 and 86400 then
    raise exception 'A rate limit window is 1 second to 1 day.' using errcode = '22023';
  end if;

  -- Nothing to count (a HEAD): only whether it's over already. A row counts at least 1.
  if p_amount = 0 then
    select r.hits into v_spent from private.rate_limits r where r.key_hash = sha256(convert_to(p_key, 'UTF8')) and r.reset_at > now();
    return coalesce(v_spent, 0) <= p_max;
  end if;

  insert into private.rate_limits as r (key_hash, hits, reset_at)
  values (sha256(convert_to(p_key, 'UTF8')), least(p_amount, p_max + 1), now() + make_interval(secs => p_window_seconds))
  on conflict (key_hash) do update set
    -- A finished window starts over; otherwise add it, stopping just past the limit (where it stays,
    -- even for an amount of 0, until the window is over).
    hits = case when r.reset_at <= now() then excluded.hits else least(r.hits::bigint + p_amount, p_max + 1)::integer end,
    reset_at = case when r.reset_at <= now() then excluded.reset_at else r.reset_at end
  returning r.hits into v_spent;

  delete from private.rate_limits
  where key_hash in (
    select key_hash from private.rate_limits where reset_at < now()
    order by reset_at limit 20 for update skip locked
  );

  return v_spent <= p_max;
end $$;

-- ---------------------------------------------------------------------------------------------
-- A plan file's preview copy counts with it
-- ---------------------------------------------------------------------------------------------

-- As 20261028000400_storage_limits.sql, with a plan file's small preview copy
-- (plan_files.preview_path, 20261118000100_plan_previews.sql) counted the way its file is: in the
-- Trash with it, and for whoever added it.

/**
 * Settings → Storage and Drive, for anyone on the team (not subs):
 *   { used_bytes, trash_bytes, files, limit_bytes, limit_mode, default_bytes, default_basis,
 *     me: { used_bytes, limit_bytes, limit_source } }
 * used_bytes is every stored file, the Trash's (trash_bytes) included; limit_bytes the limit as it
 * stands (the company's own, the default, or null for none); me the person's own uploads still in
 * use, and their limit ('person' or 'role', null for none). Owners and admins also get
 *   by_person: [{ user_id, name, role, role_name, used_bytes, limit_bytes, limit_source }]
 * (everyone active on the team or a sub; then anyone no longer on it who still has files, with no
 * role; then "Uploaded by Jobly", user_id null, for what the server stored for nobody),
 *   by_area: [{ area, bytes }] (the folder: plans, visit, quote, subs, receipts, applicants, kb,
 * equipment, tickets, chat, measurements..., and 'trash' for everything in the Trash), and
 *   roles: [{ role_key, name, limit_bytes }] (the limits set for roles).
 * Planned for the company asked about each time (a generic plan can't tell one company's files from
 * all of them), never compiled (JIT takes longer than the look itself), and added up by hashing, not
 * sorting: there are only a handful of groups, which the planner can't foresee.
 */
create or replace function public.storage_overview(p_company uuid) returns jsonb
language plpgsql stable security definer set search_path = ''
set plan_cache_mode = force_custom_plan set jit = off set enable_sort = off as $$
declare
  v_me uuid := (select auth.uid());
  v_office boolean;
  v_storage jsonb;
  v_used bigint;
  v_trash bigint;
  v_files bigint;
  v_mine bigint;
  v_people jsonb;
  v_areas jsonb;
  v_out jsonb;
begin
  if not private.is_member(p_company) then
    raise exception 'Only the team can see how much storage is used.' using errcode = '42501';
  end if;
  v_office := private.has_role(p_company, '{owner,admin}');
  select private.storage_of(c.settings) into v_storage from public.companies c where c.id = p_company;

  -- One look through the company's files, each with who added it (a plan file the server stored: who
  -- added it) and whether it's in the Trash, added up by area, person and Trash: a handful of rows,
  -- however many files there are. The Trash is joined on the path (a path is in it once at most), so
  -- its paths are hashed however many there are, a big Trash in batches on disk. (Asking "o.name in
  -- (the Trash's paths)" for each file hashes them only while they fit in memory, and past that
  -- compares every file with every path in the Trash, which takes minutes for a big company.)
  with marked as materialized (
    select x.area, x.uploader, x.trashed, sum(x.bytes)::bigint as bytes, count(*) as files
    from (
      select case when split_part(o.name, '/', 3) = '' then 'other' else split_part(o.name, '/', 2) end as area,
        coalesce(o.owner, case when split_part(o.name, '/', 2) = 'plans' then (select f.created_by from public.plan_files f where f.path = o.name or f.preview_path = o.name limit 1) end) as uploader,
        t.id is not null or d.id is not null or dp.id is not null as trashed,
        private.storage_object_bytes(o.metadata) as bytes
      from storage.objects o
      left join public.trashed_files t on t.path = o.name and t.company_id = p_company
      left join public.plan_files d on d.path = o.name and d.company_id = p_company and d.deleted_at is not null
      left join public.plan_files dp on dp.preview_path = o.name and dp.company_id = p_company and dp.deleted_at is not null
      where o.bucket_id = 'files' and o.name collate "C" >= p_company::text || '/' and o.name collate "C" < p_company::text || '0'
    ) x
    group by x.area, x.uploader, x.trashed
  ), people as materialized (
    select m.uploader, sum(m.bytes)::bigint as bytes from marked m where not m.trashed group by m.uploader
  )
  select
    coalesce((select sum(m.bytes) from marked m), 0)::bigint,
    coalesce((select sum(m.bytes) from marked m where m.trashed), 0)::bigint,
    coalesce((select sum(m.files) from marked m), 0)::bigint,
    coalesce((select p.bytes from people p where p.uploader = v_me), 0)::bigint,
    case when v_office then (
      select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'name', x.name, 'role', x.role, 'role_name', x.role_name,
          'used_bytes', x.used, 'limit_bytes', x.limit_bytes, 'limit_source', x.limit_source) order by x.kind, x.used desc, lower(x.name)), '[]')
      from (
        select 1 as kind, l.user_id, coalesce(nullif(pr.full_name, ''), pr.email, 'Someone') as name, l.role::text as role,
          coalesce(cr.name, private.storage_level_label(l.role::text)) as role_name, coalesce(u.bytes, 0) as used, l.limit_bytes, l.limit_source
        from private.storage_member_limits(p_company) l
        left join public.profiles pr on pr.user_id = l.user_id
        left join public.company_roles cr on cr.id = l.role_id
        left join people u on u.uploader = l.user_id
        where l.active
        union all
        select 2, u.uploader, coalesce(nullif(pr.full_name, ''), pr.email, 'Someone no longer on the team'), null::text, null::text, u.bytes, null::bigint, null::text
        from people u
        left join public.profiles pr on pr.user_id = u.uploader
        where u.uploader is not null and u.bytes > 0
          and not exists (select 1 from public.memberships m where m.company_id = p_company and m.user_id = u.uploader and m.active)
        union all
        select 3, null::uuid, 'Uploaded by Jobly', null::text, null::text, u.bytes, null::bigint, null::text
        from people u where u.uploader is null and u.bytes > 0
      ) x)
    end,
    case when v_office then (
      select coalesce(jsonb_agg(jsonb_build_object('area', a.area, 'bytes', a.bytes) order by a.bytes desc, a.area), '[]')
      from (
        select m.area, sum(m.bytes)::bigint as bytes from marked m where not m.trashed group by m.area
        union all
        select 'trash', sum(m.bytes)::bigint from marked m where m.trashed having count(*) > 0
      ) a)
    end
  into v_used, v_trash, v_files, v_mine, v_people, v_areas;

  select jsonb_build_object(
    'used_bytes', v_used, 'trash_bytes', v_trash, 'files', v_files,
    'limit_bytes', private.storage_company_limit(v_storage), 'limit_mode', private.storage_limit_mode(v_storage),
    'default_bytes', private.storage_bytes(v_storage -> 'default_bytes'),
    'default_basis', case when jsonb_typeof(v_storage -> 'default_basis') = 'string' then v_storage ->> 'default_basis' end,
    'me', jsonb_build_object('used_bytes', v_mine, 'limit_bytes', l.limit_bytes, 'limit_source', l.limit_source))
  into v_out
  from (select 1) one
  left join private.storage_member_limits(p_company) l on l.user_id = v_me;

  if v_office then
    v_out := v_out || jsonb_build_object('by_person', v_people, 'by_area', v_areas, 'roles', (
      select coalesce(jsonb_agg(jsonb_build_object('role_key', a.role_key, 'name', coalesce(cr.name, private.storage_level_label(a.role_key)), 'limit_bytes', a.limit_bytes)
          order by cr.id is not null, array_position(array['admin', 'office', 'estimator', 'crew_lead', 'field_crew'], a.role_key), lower(cr.name)), '[]')
      from public.storage_allowances a
      left join public.company_roles cr on cr.company_id = a.company_id and cr.id::text = a.role_key
      where a.company_id = p_company and a.role_key is not null));
  end if;
  return v_out;
end $$;

/**
 * The storage gateway's check before an upload (apps/api/src/lib/storageLimits.ts): what the company
 * has stored (the Trash's too) and its limit as it stands (null for none); what p_user uploaded that's
 * still in use, and the limit they're held to (null for none, and always for owners). One row, also
 * for a company or person it doesn't know. The server's alone. One look through the company's files;
 * only the person's own are looked up in the Trash. Planned for the company asked about each time,
 * and never compiled, as storage_overview.
 */
create or replace function public.storage_snapshot(p_company uuid, p_user uuid)
returns table (company_used bigint, company_limit bigint, user_used bigint, user_limit bigint, user_is_owner boolean)
language plpgsql stable security definer set search_path = '' set plan_cache_mode = force_custom_plan set jit = off as $$
declare
  v_storage jsonb;
  v_used bigint;
  v_theirs bigint;
  v_limit bigint;
  v_owner boolean;
begin
  select private.storage_of(c.settings) into v_storage from public.companies c where c.id = p_company;
  -- The person's own: what they stored, or a plan file the server stored that they added, and in
  -- neither case in the Trash.
  select coalesce(sum(x.bytes), 0), coalesce(sum(case when x.maybe_theirs then
      case when not exists (select 1 from public.trashed_files t where t.path = x.name)
        and not exists (select 1 from public.plan_files f where (f.path = x.name or f.preview_path = x.name)
                        and (f.deleted_at is not null or (x.owner is null and f.created_by is distinct from p_user)))
        and (x.owner is not null or exists (select 1 from public.plan_files f where f.path = x.name or f.preview_path = x.name))
      then x.bytes end
    end), 0)
  into v_used, v_theirs
  from (
    select o.name, o.owner, private.storage_object_bytes(o.metadata) as bytes,
      coalesce(p_user is not null and (o.owner = p_user or (o.owner is null and split_part(o.name, '/', 2) = 'plans')), false) as maybe_theirs
    from storage.objects o
    where o.bucket_id = 'files' and o.name collate "C" >= p_company::text || '/' and o.name collate "C" < p_company::text || '0'
  ) x;
  select l.limit_bytes, l.role = 'owner' and l.active into v_limit, v_owner
  from private.storage_member_limits(p_company) l where l.user_id = p_user;
  return query select v_used, private.storage_company_limit(v_storage), v_theirs, v_limit, coalesce(v_owner, false);
end $$;

-- ---------------------------------------------------------------------------------------------
-- Who calls what
-- ---------------------------------------------------------------------------------------------

revoke all on function private.storage_dollars(jsonb), private.storage_from_dollars(numeric, numeric, bigint) from public;
revoke execute on function public.storage_set_limit(uuid, text, bigint, numeric) from public, anon;
grant execute on function public.storage_set_limit(uuid, text, bigint, numeric) to authenticated;
revoke execute on function public.storage_set_rate(uuid, numeric, bigint), public.rate_limit_spend(text, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.storage_set_rate(uuid, numeric, bigint), public.rate_limit_spend(text, integer, integer, integer) to service_role;

notify pgrst, 'reload schema';
