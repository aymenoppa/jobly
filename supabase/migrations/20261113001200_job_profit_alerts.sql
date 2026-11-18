-- Job profit alerts: "Tell me when a job's profit falls below X%" (Jobber Plus's job profit alerts).
--
--   settings.profit_alert_percent   the company's line, a whole percent from 1 to 99 (Settings →
--                                   Company → Job costing; owners and admins, who change the
--                                   company's settings). Off unless set.
--   private.job_cost_changes        which jobs' costs changed since the hourly check last looked:
--                                   time on them, its rate as it's approved, expenses, logged
--                                   materials, sub and crew pay, and their lines (and so their
--                                   price). The tables' own triggers note the job; nothing else is
--                                   touched, so a job's updated_at (which Finance → Profit goes by)
--                                   stays as it was.
--   public.job_profit_alerts        where each job checked stands: below the line or not, at what
--                                   margin, and when the office was told. Read by the Jobs page's
--                                   Below your margin, for the people who see job costs.
--
-- The server's hourly task (apps/api/src/services/profitAlerts.ts) costs each changed one-off job
-- with core's jobCost, the calculation the job page and Finance use, and tells the people who see
-- job costs once as a job goes below the line (bell and push), not again until it has come back up
-- and gone below again. Repeating jobs aren't checked: their price is for a visit or a month, and
-- what a stretch of their work cost can't be set against what it was billed with the data there is.
-- After the line is changed (or first set), the jobs already below it are listed, not told about
-- one by one: the next check looks at every open one-off job quietly and sends one note saying how
-- many there are.
--
-- supabase/tests/job_profit_alerts_test.sql covers it.

-- ---------------------------------------------------------------------------------------------
-- Which jobs' costs changed
-- ---------------------------------------------------------------------------------------------

-- No foreign key to jobs: a job's rows are deleted with it, and their triggers note it as they go.
-- The check drops the notes of jobs that are gone.
create table private.job_cost_changes (
  job_id uuid primary key,
  company_id uuid not null,
  changed_at timestamptz not null default now()
);
create index job_cost_changes_company_idx on private.job_cost_changes (company_id, changed_at);
comment on table private.job_cost_changes is 'Jobs whose costs changed since the hourly profit check last looked at them (private.note_job_costs_changed).';

create function private.note_job_cost_change(p_job uuid, p_company uuid) returns void
language sql security definer set search_path = '' as $$
  insert into private.job_cost_changes (job_id, company_id) values (p_job, p_company)
  on conflict (job_id) do update set changed_at = now()
$$;

-- On the tables whose rows a job's costs are made of: the job a row is on (both, when it moves).
create function private.note_job_costs_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op <> 'INSERT' and old.job_id is not null then
    perform private.note_job_cost_change(old.job_id, old.company_id);
  end if;
  if tg_op <> 'DELETE' and new.job_id is not null and (tg_op = 'INSERT' or new.job_id is distinct from old.job_id) then
    perform private.note_job_cost_change(new.job_id, new.company_id);
  end if;
  return null;
end $$;
revoke all on function private.note_job_cost_change(uuid, uuid), private.note_job_costs_changed() from public;

-- Only the columns that cost something: a note on a time entry or an expense's description doesn't count.
create trigger costs_changed after insert or delete on public.time_entries
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed_update after update of job_id, user_id, started_at, ended_at, labor_rate on public.time_entries
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed after insert or delete on public.expenses
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed_update after update of job_id, amount, in_line_costs on public.expenses
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed after insert or delete on public.job_materials
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed_update after update of job_id, service_id, name, unit, quantity on public.job_materials
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed after insert or delete on public.job_pay
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed_update after update of job_id, status, total, paid_amount on public.job_pay
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed after insert or delete on public.job_line_items
  for each row execute function private.note_job_costs_changed();
create trigger costs_changed_update after update of job_id, quantity, unit_price, unit_cost, unit_labor_cost, service_id, unit, parts on public.job_line_items
  for each row execute function private.note_job_costs_changed();

-- ---------------------------------------------------------------------------------------------
-- Where each job stands
-- ---------------------------------------------------------------------------------------------

create table public.job_profit_alerts (
  job_id uuid primary key,
  company_id uuid not null,
  below boolean not null default false,
  -- The margin it was checked at, as a percent, and the line it was checked against.
  margin numeric(8, 1),
  line integer,
  -- When the office was last told it went below (null: listed only, or never below).
  told_at timestamptz,
  checked_at timestamptz not null default now(),
  foreign key (company_id, job_id) references public.jobs (company_id, id) on delete cascade
);
create index job_profit_alerts_below_idx on public.job_profit_alerts (company_id) where below;
comment on table public.job_profit_alerts is 'Where the hourly profit check last found each job against the company''s profit line (settings.profit_alert_percent). Written by the server alone.';

-- For the people who see job costs, as expenses and job pay costs are.
alter table public.job_profit_alerts enable row level security;
create policy job_profit_alerts_read on public.job_profit_alerts for select to authenticated
  using (private.has_role(company_id, '{owner,admin,office}') and private.has_perm(company_id, 'job_costs'));
revoke insert, update, delete, truncate on public.job_profit_alerts from authenticated;
revoke all on public.job_profit_alerts from anon;

-- The line each company's jobs were last checked against, so a change to it is seen.
create table private.profit_alert_lines (
  company_id uuid primary key references public.companies (id) on delete cascade,
  line integer not null,
  checked_at timestamptz not null default now()
);

-- The company's line: a whole percent from 1 to 99, or null when it's off (core profitAlertPercent).
create function private.profit_alert_line(p_company uuid) returns integer
language sql stable security definer set search_path = '' as $$
  select case when s ~ '^\s*[0-9]{1,2}\s*$' and s::integer between 1 and 99 then s::integer end
  from (select c.settings ->> 'profit_alert_percent' as s from public.companies c where c.id = p_company) x
$$;

-- The people who see job costs: owners, admins and office staff with the area.
create function private.job_costs_office(p_company uuid) returns setof uuid
language sql stable security definer set search_path = '' as $$
  select m.user_id
  from public.memberships m
  left join public.company_roles cr on cr.id = m.role_id
  where m.company_id = p_company and m.active and m.role in ('owner', 'admin', 'office')
    and 'job_costs' = any (coalesce(cr.permissions, private.level_permissions(m.role)))
$$;
revoke all on function private.profit_alert_line(uuid), private.job_costs_office(uuid) from public;

-- ---------------------------------------------------------------------------------------------
-- The server's hourly check
-- ---------------------------------------------------------------------------------------------

/**
 * The companies to check, each with its line and whether it changed since the last check (`sweep`:
 * every open one-off job is looked at, quietly). A company that has turned it off forgets where its
 * jobs stood and what changed, so turning it on again starts afresh.
 */
create function public.profit_alert_companies()
returns table (company_id uuid, line integer, sweep boolean)
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.job_profit_alerts a where private.profit_alert_line(a.company_id) is null;
  delete from private.profit_alert_lines l where private.profit_alert_line(l.company_id) is null;
  delete from private.job_cost_changes c where private.profit_alert_line(c.company_id) is null;
  return query
    select c.id, private.profit_alert_line(c.id), l.line is distinct from private.profit_alert_line(c.id)
    from public.companies c
    left join private.profit_alert_lines l on l.company_id = c.id
    where private.profit_alert_line(c.id) is not null;
end $$;

/** A company's jobs to look at: those whose costs changed (`sweep`: also every open one-off job, and those it listed as below). */
create function public.profit_alert_jobs(p_company uuid, p_sweep boolean default false)
returns table (job_id uuid, changed_at timestamptz)
language sql stable security definer set search_path = '' as $$
  -- Once each, with its change note's time when it has one (the note is cleared only if it's still that).
  select x.job_id, max(x.changed_at)
  from (
    select c.job_id, c.changed_at from private.job_cost_changes c where c.company_id = p_company
    union all
    select j.id, null from public.jobs j
    where p_sweep and j.company_id = p_company and j.kind <> 'recurring' and j.status in ('active', 'requires_invoicing')
    union all
    select a.job_id, null from public.job_profit_alerts a where p_sweep and a.company_id = p_company and a.below
  ) x
  group by x.job_id
$$;

/**
 * What the check found. p_checks: [{job_id, changed_at, below, margin, tell, title}], decided by the
 * server (core profitAlertDecision). Each job's standing is saved; one going below is told about
 * (bell, and push by the people's own choices: kind 'job_profit', under Other alerts) only if it
 * wasn't already below, so two checks at once tell nobody twice. Each job's change note is cleared
 * if it's still the one the check read (changed_at): a change since then is looked at next time.
 * Notes of jobs that are gone go too. Returns how many jobs were told about.
 */
create function public.record_profit_checks(p_company uuid, p_line integer, p_checks jsonb)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  r record;
  v_was boolean;
  v_told integer := 0;
begin
  for r in
    select x.job_id, coalesce(x.below, false) as below, x.margin, coalesce(x.tell, false) as tell, x.title
    from jsonb_to_recordset(coalesce(p_checks, '[]')) as x(job_id uuid, below boolean, margin numeric, tell boolean, title text)
    join public.jobs j on j.id = x.job_id and j.company_id = p_company
    order by x.job_id
  loop
    select a.below into v_was from public.job_profit_alerts a where a.job_id = r.job_id for update;
    insert into public.job_profit_alerts (job_id, company_id, below, margin, line, told_at, checked_at)
    values (r.job_id, p_company, r.below, round(r.margin, 1), p_line, null, now())
    on conflict (job_id) do update set below = excluded.below, margin = excluded.margin, line = excluded.line, checked_at = now();
    if r.below and r.tell and not coalesce(v_was, false) then
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

/**
 * After a sweep: the line is the one its jobs were checked against now, and the people who see job
 * costs get one note saying how many jobs are below it (none when there aren't any), linking to them.
 */
create function public.finish_profit_sweep(p_company uuid, p_line integer) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_below integer;
begin
  insert into private.profit_alert_lines (company_id, line, checked_at) values (p_company, p_line, now())
  on conflict (company_id) do update set line = excluded.line, checked_at = now();
  select count(*) into v_below from public.job_profit_alerts a join public.jobs j on j.id = a.job_id
  where a.company_id = p_company and a.below and j.status <> 'archived';
  if v_below > 0 then
    insert into public.notifications (company_id, user_id, kind, title, body, link)
    select p_company, u, 'job_profit',
           case when v_below = 1 then '1 job is below your ' || p_line || '% profit line' else v_below || ' jobs are below your ' || p_line || '% profit line' end,
           'They''re listed under Below your margin on the Jobs page. From now on you''re told as each job goes below.', '/jobs?margin=below'
    from private.job_costs_office(p_company) u;
  end if;
  return v_below;
end $$;

revoke all on function public.profit_alert_companies(), public.profit_alert_jobs(uuid, boolean), public.record_profit_checks(uuid, integer, jsonb),
  public.finish_profit_sweep(uuid, integer) from public, anon, authenticated;
grant execute on function public.profit_alert_companies(), public.profit_alert_jobs(uuid, boolean), public.record_profit_checks(uuid, integer, jsonb),
  public.finish_profit_sweep(uuid, integer) to service_role;

-- Its policies look the person's roles up once a query, not once a row (20261018000990_policy_lookups.sql).
select private.fold_member_checks('public.job_profit_alerts');

notify pgrst, 'reload schema';
