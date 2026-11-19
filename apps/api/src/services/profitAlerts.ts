/**
 * Job profit alerts (supabase/migrations/20261113001200_job_profit_alerts.sql): every hour, each
 * company with a profit line (settings.profit_alert_percent) has the one-off jobs whose costs changed
 * since the last look costed with core's costJobRows, the function the job page costs a job with,
 * from the same rows (sub and crew pay from the database's one sum of it), and the
 * people who see job costs are told once as a job goes below the line. Right after the line changes,
 * every open one-off job is looked at quietly instead, and they get one note saying how many are below.
 * A job that was there when the line took effect and is first looked at later (a finished job whose
 * timesheet is approved) is listed quietly too: the database decides that as it records the check
 * (20261113001688_first_profit_look_is_quiet.sql), so `told` is its count, not this file's.
 * Repeating jobs aren't checked (belowProfitLine says why).
 */
import { belowProfitLine, costJobRows, profitAlertDecision, profitAlertText, type CostedLine } from "@jobly/core";
import { reportError } from "../lib/monitoring";
import type { Db } from "../lib/supabase";
import { timeRates } from "./payRates";

/** Jobs a request: keeps the address short enough (and the rates' lookup to one page or two). */
const JOBS_AT_ONCE = 200;

/** The margins a job's standing can keep: one decimal, to ±9,999,999.9% (job_profit_alerts.margin). */
export const MARGIN_KEPT = 9_999_999.9;
/** A margin as it's kept: a job priced at a cent with real costs is millions of percent under, which the column can't hold. */
export const keptMargin = (margin: number | null) => (margin === null ? null : Math.max(-MARGIN_KEPT, Math.min(MARGIN_KEPT, margin)));

interface Job {
  id: string;
  number: number | null;
  kind: string;
  status: string;
  client: { display_name: string } | null;
  financials: { contract_total: number | string | null } | null;
  lines: CostedLine[];
}

/** Every row a query finds, a page of 1,000 at a time (PostgREST returns no more than that at once). */
async function everyPage<T>(page: (from: number, to: number) => PromiseLike<{ data: T[] | null; error: { message: string } | null }>): Promise<T[]> {
  const out: T[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await page(from, from + 999);
    if (error) throw new Error(error.message);
    out.push(...(data ?? []));
    if ((data ?? []).length < 1000) return out;
  }
}

const group = <T extends { job_id: string | null }>(rows: readonly T[]) => {
  const out = new Map<string, T[]>();
  for (const r of rows) if (r.job_id) (out.get(r.job_id) ?? out.set(r.job_id, []).get(r.job_id)!).push(r);
  return out;
};

/** Each of these jobs' costs, read with the server's key: the rows the job page reads for it. */
export async function costJobs(admin: Db, companyId: string, ids: readonly string[]) {
  const jobs = await everyPage<Job>((f, t) =>
    admin
      .from("jobs")
      .select("id, number, kind, status, client:clients(display_name), financials:job_financials(contract_total), lines:job_line_items(quantity, unit_cost, unit_labor_cost, service_id, unit, parts)")
      .eq("company_id", companyId)
      .in("id", [...ids])
      .order("id")
      .range(f, t) as never,
  );
  const [time, expenses, materials, pay, rates] = await Promise.all([
    everyPage((f, t) => admin.from("time_entries").select("id, job_id, user_id, started_at, ended_at").eq("company_id", companyId).in("job_id", [...ids]).order("id").range(f, t)),
    everyPage((f, t) => admin.from("expenses").select("job_id, amount, in_line_costs").eq("company_id", companyId).in("job_id", [...ids]).order("id").range(f, t)),
    everyPage((f, t) => admin.from("job_materials").select("job_id, service_id, name, unit, quantity").eq("company_id", companyId).in("job_id", [...ids]).order("id").range(f, t)),
    // Sub and crew pay as the job page reads it: the database's own sum (job_pay_costs, here for the
    // server), which counts a new price still waiting for an answer at the one already agreed.
    admin.rpc("job_pay_costs_for_check", { p_company: companyId, p_jobs: [...ids] }).then(({ data, error }) => {
      if (error) throw new Error(error.message);
      return (data ?? []) as Array<{ job_id: string; amount: number | string | null; payees: number }>;
    }),
    timeRates(admin, companyId, { job_ids: ids }),
  ]);
  const [times, spends, logs, pays] = [group(time), group(expenses), group(materials), group(pay)];
  return jobs.map((job) => ({
    job,
    cost: costJobRows({
      price: Number(job.financials?.contract_total ?? 0),
      lines: job.lines ?? [],
      time: times.get(job.id) ?? [],
      rates,
      pay: pays.get(job.id) ?? [],
      expenses: spends.get(job.id) ?? [],
      logged: logs.get(job.id) ?? [],
    }),
  }));
}

/** One company's check: the jobs whose costs changed, or (`sweep`, after its line changed) every open one-off job, quietly. */
async function checkCompany(admin: Db, company: { company_id: string; line: number; sweep: boolean }) {
  // Every job to look at, a page at a time: a company's first look after setting its margin can be
  // more than the 1,000 rows one request brings, and the ones left out would never be listed.
  const jobs = await everyPage<{ job_id: string; changed_at: string | null }>((f, t) =>
    admin.rpc("profit_alert_jobs", { p_company: company.company_id, p_sweep: company.sweep }).order("job_id").range(f, t),
  );
  const seen = new Map<string, string | null>();
  for (const r of jobs) if (!seen.has(r.job_id) || r.changed_at) seen.set(r.job_id, r.changed_at);
  const ids = [...seen.keys()];
  const before = ids.length
    ? await everyPage<{ job_id: string }>((f, t) => admin.from("job_profit_alerts").select("job_id, below").eq("company_id", company.company_id).eq("below", true).order("job_id").range(f, t))
    : [];
  const wasBelow = new Set(before.map((r) => r.job_id));
  let told = 0;
  for (let i = 0; i < ids.length; i += JOBS_AT_ONCE) {
    const lot = ids.slice(i, i + JOBS_AT_ONCE);
    const costed = await costJobs(admin, company.company_id, lot);
    const checks = costed.map(({ job, cost }) => {
      // An archived job leaves the list; it's nobody's to worry about now.
      const below = job.status !== "archived" && belowProfitLine(job, cost, company.line);
      const decision = profitAlertDecision(wasBelow.has(job.id), below, company.sweep);
      return {
        job_id: job.id,
        changed_at: seen.get(job.id) ?? null,
        below: decision.below,
        tell: decision.tell,
        margin: keptMargin(cost.margin),
        title: cost.margin === null ? null : profitAlertText({ number: job.number, client: job.client?.display_name ?? null }, cost.margin, company.line),
      };
    });
    // Jobs that are gone: their notes are cleared with the rest.
    const found = new Set(checks.map((c) => c.job_id));
    for (const id of lot) if (!found.has(id)) checks.push({ job_id: id, changed_at: seen.get(id) ?? null, below: false, tell: false, margin: null, title: null });
    const { data: count, error: recordError } = await admin.rpc("record_profit_checks", { p_company: company.company_id, p_line: company.line, p_checks: checks as never });
    if (recordError) throw new Error(recordError.message);
    told += count ?? 0;
  }
  let listed = 0;
  if (company.sweep) {
    const { data: below, error: sweepError } = await admin.rpc("finish_profit_sweep", { p_company: company.company_id, p_line: company.line });
    if (sweepError) throw new Error(sweepError.message);
    listed = below ?? 0;
  }
  return { checked: ids.length, told, listed };
}

/** The hourly task: every company with a profit line, each on its own (one that fails is reported, and the rest still run). */
export async function checkJobProfits(admin: Db) {
  const { data, error } = await admin.rpc("profit_alert_companies");
  if (error) throw new Error(error.message);
  const totals = { companies: 0, checked: 0, told: 0, listed: 0, failed: 0 };
  for (const company of data ?? []) {
    try {
      const r = await checkCompany(admin, company);
      totals.companies++;
      totals.checked += r.checked;
      totals.told += r.told;
      totals.listed += r.listed;
    } catch (err) {
      totals.failed++;
      console.error("Job profit check failed", company.company_id, err instanceof Error ? err.message : err);
      reportError(err, { task: "profits", company: company.company_id });
    }
  }
  return totals;
}
