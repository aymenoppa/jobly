-- The first look at a job after the profit margin is set or changed is always quiet.
--
-- Setting the margin promises a list, not a flood: the jobs already below it are listed under
-- "Below your margin" and one note says how many. That quiet look took in only the open jobs. A
-- finished job was first looked at whenever something later touched its costs, as a job that had
-- just gone below, and approving a week's timesheets touches every job in them (the rate each
-- entry is approved at is written on it). Twenty finished jobs under the line in last week's time
-- meant twenty bell and push notices each.
--
-- Now record_profit_checks decides it, whatever brought the job in. A job that was there when the
-- margin took effect (private.profit_alert_lines.checked_at, set as the quiet look finishes) and
-- hasn't been looked at since (no standing against this margin) is only listed the first time. From
-- then on it's told about when it goes below, having been above. A job made after the margin took
-- effect is told about the first time it's found below: it was never listed anywhere.
--
-- supabase/tests/job_profit_check_test.sql covers it.

/**
 * As in 20261113001200_job_profit_alerts.sql, and a job's first look since the margin was set or
 * changed tells nobody (see the top of this file).
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
    v_was := null;
    v_line := null;
    select a.below, a.line into v_was, v_line from public.job_profit_alerts a where a.job_id = r.job_id for update;
    -- Not looked at since this margin took effect, and it was there when it did: listed, not told.
    v_first := v_line is distinct from p_line and (v_since is null or r.created_at <= v_since);
    insert into public.job_profit_alerts (job_id, company_id, below, margin, line, told_at, checked_at)
    values (r.job_id, p_company, r.below, round(r.margin, 1), p_line, null, now())
    on conflict (job_id) do update set below = excluded.below, margin = excluded.margin, line = excluded.line, checked_at = now();
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
