-- The hourly profit check counts sub and crew pay exactly as the job page does.
--
-- The job page, Finance and the assistants ask public.job_pay_costs what a job's pay costs: agreed,
-- done or paid, and a new price still waiting for an answer at the price already agreed. The
-- hourly check couldn't call it (it answers only the office signed in), so it read job_pay itself,
-- and left out pay with a new price waiting. A $10,000 job with a sub agreed at $7,500, re-offered
-- $6,500: the job page went on costing $7,500 while the check saw no pay at all, took the job off
-- "Below your margin", and told everyone a second time when the sub answered.
--
-- Now the sum is in one place, private.job_pay_cost_rows, and both read it: job_pay_costs for the
-- people who see job costs, as before, and job_pay_costs_for_check for the server's hourly check.
--
-- supabase/tests/job_profit_check_test.sql feeds the same job to both.

/** What each job's sub and crew pay costs, and how many are paid on it. For whoever may know: the two functions below decide who. */
create function private.job_pay_cost_rows(p_jobs uuid[])
returns table (job_id uuid, company_id uuid, amount numeric, payees integer)
language sql stable security definer set search_path = '' as $$
  select p.job_id, p.company_id,
    sum(case when p.status = 'paid' then p.paid_amount when p.status = 'offered' then (p.accepted_snapshot ->> 'total')::numeric else p.total end),
    count(*)::integer
  from public.job_pay p
  where p.job_id = any (p_jobs) and (p.status in ('accepted', 'done', 'paid') or (p.status = 'offered' and p.accepted_snapshot is not null))
  group by p.job_id, p.company_id
$$;
revoke all on function private.job_pay_cost_rows(uuid[]) from public;

/** As in 20261025004002_sub_pay_seams.sql, the same sum read from private.job_pay_cost_rows: for the office with job costs. */
create or replace function public.job_pay_costs(p_jobs uuid[])
returns table (job_id uuid, amount numeric, payees integer)
language sql stable security definer set search_path = '' as $$
  select r.job_id, r.amount, r.payees
  from private.job_pay_cost_rows(p_jobs) r
  where r.company_id = any (private.role_companies('{owner,admin,office}')) and r.company_id = any (private.perm_companies('job_costs'))
$$;

/** The same for the server's hourly profit check (services/profitAlerts.ts), one company's jobs at a time. */
create function public.job_pay_costs_for_check(p_company uuid, p_jobs uuid[])
returns table (job_id uuid, amount numeric, payees integer)
language sql stable security definer set search_path = '' as $$
  select r.job_id, r.amount, r.payees from private.job_pay_cost_rows(p_jobs) r where r.company_id = p_company
$$;
revoke execute on function public.job_pay_costs_for_check(uuid, uuid[]) from public, anon, authenticated;
grant execute on function public.job_pay_costs_for_check(uuid, uuid[]) to service_role;

notify pgrst, 'reload schema';
