-- The hourly profit check: two checks at once tell people once, a margin too large to keep doesn't
-- stall a company's check, and a changed pay rate has the jobs it re-costs looked at again.
--
--   Told once      record_profit_checks read a job's standing before it wrote one. For a job with
--                  no standing yet there was nothing to lock, so two servers checking at the same
--                  moment could both find it new and both tell everyone. Now each job's standing is
--                  made first (an empty one: not below, checked against no margin) and locked, so
--                  the second check waits and then sees what the first recorded.
--   Margins        A margin is kept to one decimal up to ±9,999,999.9%. A job priced at a cent with
--                  $1,000 of costs is past that, and the error undid the whole company's check,
--                  every hour. It's kept as the nearest margin that fits (the server clamps it too).
--   Pay rates      Time that isn't approved yet is costed at the person's rate today
--                  (memberships.labor_rate). Changing that rate re-costs every job with such time,
--                  and nothing noted them, so a job the new rate took below the margin wasn't
--                  looked at until something else touched it. Now those jobs are noted.
--
-- (The check itself also reads its jobs a page at a time now: apps/api/src/services/profitAlerts.ts.)
-- supabase/tests/job_profit_check_test.sql covers it.

/**
 * As in 20261113001688_first_profit_look_is_quiet.sql, with each job's standing made and locked
 * before it's read, and its margin kept within what the column holds.
 */
create or replace function public.record_profit_checks(p_company uuid, p_line integer, p_checks jsonb)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_was boolean;
  v_line integer;
  v_since timestamptz;
  v_first boolean;
  v_told integer := 0;
begin
  -- When this margin took effect: when the quiet look after it was set finished. Null while that
  -- look is still going (everything it records is quiet anyway).
  select l.checked_at into v_since from private.profit_alert_lines l where l.company_id = p_company and l.line = p_line;
  for r in
    select x.job_id, coalesce(x.below, false) as below, x.margin, coalesce(x.tell, false) as tell, x.title, j.created_at
    from jsonb_to_recordset(coalesce(p_checks, '[]')) as x(job_id uuid, below boolean, margin numeric, tell boolean, title text)
    join public.jobs j on j.id = x.job_id and j.company_id = p_company
    order by x.job_id
  loop
    -- A standing to lock, for a job that has none: another check recording the same job at this
    -- moment waits here until this one is done, then reads what it wrote.
    insert into public.job_profit_alerts (job_id, company_id, below, margin, line, told_at, checked_at)
    values (r.job_id, p_company, false, null, null, null, now())
    on conflict (job_id) do nothing;
    select a.below, a.line into v_was, v_line from public.job_profit_alerts a where a.job_id = r.job_id for update;
    -- Not looked at since this margin took effect, and it was there when it did: listed, not told.
    v_first := v_line is distinct from p_line and (v_since is null or r.created_at <= v_since);
    update public.job_profit_alerts
       set below = r.below, margin = least(greatest(round(r.margin, 1), -9999999.9), 9999999.9), line = p_line, checked_at = now()
     where job_id = r.job_id;
    if r.below and r.tell and not coalesce(v_was, false) and not v_first then
      update public.job_profit_alerts set told_at = now() where job_id = r.job_id;
      insert into public.notifications (company_id, user_id, kind, title, body, link)
      select p_company, u, 'job_profit', left(coalesce(nullif(trim(r.title), ''), 'A job is below your profit line'), 300),
             'Open the job to see what it cost.', '/jobs/' || r.job_id
      from private.job_costs_office(p_company) u;
      v_told := v_told + 1;
    end if;
  end loop;
  delete from private.job_cost_changes c
  using jsonb_to_recordset(coalesce(p_checks, '[]')) as x(job_id uuid, changed_at timestamptz)
  where c.company_id = p_company and c.job_id = x.job_id and x.changed_at is not null and c.changed_at <= x.changed_at;
  delete from private.job_cost_changes c
  where c.company_id = p_company and not exists (select 1 from public.jobs j where j.id = c.job_id);
  return v_told;
end $$;
revoke all on function public.record_profit_checks(uuid, integer, jsonb) from public, anon, authenticated;
grant execute on function public.record_profit_checks(uuid, integer, jsonb) to service_role;

-- A person's pay rate changed: the jobs with time of theirs that isn't approved yet cost something
-- else now (approved time keeps the rate it was approved at), so the check looks at them again.
create function private.note_rate_change() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into private.job_cost_changes (job_id, company_id)
  select distinct t.job_id, new.company_id
    from public.time_entries t
   where t.company_id = new.company_id and t.user_id = new.user_id and t.job_id is not null and t.labor_rate is null
  on conflict (job_id) do update set changed_at = now();
  return null;
end $$;
revoke all on function private.note_rate_change() from public;
create trigger rate_changes_job_costs after update of labor_rate on public.memberships
  for each row when (new.labor_rate is distinct from old.labor_rate) execute function private.note_rate_change();
