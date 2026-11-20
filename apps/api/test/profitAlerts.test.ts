/**
 * The hourly job profit check (services/profitAlerts.ts) against a stand-in database: tables of rows
 * that eq and in filter, and the check's functions answering from `state`. What those functions do
 * in the database is tested in supabase/tests/job_profit_alerts_test.sql.
 */
import { costJobRows } from "@jobly/core";
import { describe, expect, it } from "vitest";
import type { Db } from "../src/lib/supabase";
import { timeRates } from "../src/services/payRates";
import { checkJobProfits, costJobs, keptMargin } from "../src/services/profitAlerts";

type Row = Record<string, unknown>;
const CO = "00000000-0000-4000-8000-0000000000c1";

function fakeDb(tables: Record<string, Row[]>, companies: Row[], jobs: Row[]) {
  const recorded: Array<{ args: Row }> = [];
  const swept: string[] = [];
  /** Each answer a function gave that was a list: one a page. */
  const pages: string[] = [];
  const from = (table: string) => {
    const filters: Array<(row: Row) => boolean> = [];
    const rows = () => (tables[table] ?? []).filter((row) => filters.every((keep) => keep(row)));
    const builder: Record<string, unknown> = {
      select: () => builder,
      order: () => builder,
      eq: (column: string, value: unknown) => (filters.push((row) => row[column] === value), builder),
      in: (column: string, values: unknown[]) => (filters.push((row) => values.includes(row[column])), builder),
      range: () => builder,
      then: (resolve: (r: unknown) => unknown, reject: (e: unknown) => unknown) => Promise.resolve({ data: rows(), error: null }).then(resolve, reject),
    };
    return builder;
  };
  const answer = async (fn: string, args: Row) => {
    if (fn === "profit_alert_companies") return { data: companies, error: null };
    if (fn === "profit_alert_jobs") return { data: jobs, error: null };
    // The database's one sum of a job's sub and crew pay (job_pay_cost_rows), as it answers the check.
    if (fn === "job_pay_costs_for_check") return { data: (tables.job_pay_costs ?? []).filter((r) => r.company_id === args.p_company && (args.p_jobs as string[]).includes(r.job_id as string)), error: null };
    if (fn === "record_profit_checks") {
      recorded.push({ args });
      return { data: (args.p_checks as Row[]).filter((c) => c.tell).length, error: null };
    }
    if (fn === "finish_profit_sweep") {
      swept.push(args.p_company as string);
      return { data: 1, error: null };
    }
    throw new Error(`unexpected ${fn}`);
  };
  // As PostgREST answers a function: all at once, or (ordered and cut to a range) a page of at most 1,000 rows.
  const rpc = (fn: string, args: Row) => {
    let cut: [number, number] | null = null;
    const call: Record<string, unknown> = {
      order: () => call,
      range: (f: number, t: number) => ((cut = [f, t]), call),
      then: (resolve: (r: unknown) => unknown, reject: (e: unknown) => unknown) =>
        answer(fn, args)
          .then((r) => {
            if (!Array.isArray(r.data)) return r;
            pages.push(fn);
            const [f, t] = cut ?? [0, 999];
            return { ...r, data: (r.data as Row[]).slice(f, Math.min(t + 1, f + 1000)) };
          })
          .then(resolve, reject),
    };
    return call;
  };
  return { db: { from, rpc } as unknown as Db, recorded, swept, pages };
}

// Job #12 for Maria Lopez: $1,000, its line costs $300 to make, 10 hours at $50 and $120 of dump fees: 8% profit.
const tables = (): Record<string, Row[]> => ({
  jobs: [
    { id: "j12", company_id: CO, number: 12, kind: "one_off", status: "active", client: { display_name: "Maria Lopez" }, financials: { contract_total: "1000.00" }, lines: [{ quantity: 1, unit_cost: 300, unit_labor_cost: null }] },
    { id: "j13", company_id: CO, number: 13, kind: "one_off", status: "active", client: { display_name: "Sam Lee" }, financials: { contract_total: 2000 }, lines: [{ quantity: 1, unit_cost: 300 }] },
    { id: "w1", company_id: CO, number: 14, kind: "recurring", status: "active", client: null, financials: { contract_total: 50 }, lines: [{ quantity: 1, unit_cost: 40 }] },
  ],
  time_entries: [
    { id: "t1", company_id: CO, job_id: "j12", user_id: "u1", started_at: "2026-11-10T13:00:00Z", ended_at: "2026-11-10T23:00:00Z", labor_rate: null },
    { id: "t2", company_id: CO, job_id: "w1", user_id: "u1", started_at: "2026-11-10T13:00:00Z", ended_at: "2026-11-10T23:00:00Z", labor_rate: null },
  ],
  memberships: [{ company_id: CO, user_id: "u1", labor_rate: 50 }],
  expenses: [{ company_id: CO, job_id: "j12", amount: "120.00", in_line_costs: false }, { company_id: CO, job_id: "j12", amount: "999.00", in_line_costs: true }],
  job_materials: [],
  job_pay: [],
  job_profit_alerts: [],
});

describe("one job, costed by the hourly check and by the job page", () => {
  // Job #20: $10,000, lines that cost $1,000 to make, 8 hours at $50, a $200 expense and one already in
  // the lines, 3 tons logged against 2 estimated, and a sub agreed at $7,500 who has been re-offered
  // $6,500 and hasn't answered: the database still counts the $7,500 agreed.
  const job20 = (): Record<string, Row[]> => ({
    jobs: [{
      id: "j20", company_id: CO, number: 20, kind: "one_off", status: "active", client: { display_name: "Pat Hill" }, financials: { contract_total: "10000.00" },
      lines: [{ quantity: 2, unit_cost: 400, unit_labor_cost: 50, service_id: "s-rock", unit: "ton", parts: null }, { quantity: 1, unit_cost: 200, unit_labor_cost: null, service_id: null, unit: "ea", parts: null }],
    }],
    time_entries: [
      { id: "t20", company_id: CO, job_id: "j20", user_id: "u1", started_at: "2026-11-10T13:00:00Z", ended_at: "2026-11-10T21:00:00Z", labor_rate: null },
      { id: "t21", company_id: CO, job_id: "j20", user_id: "u1", started_at: "2026-11-11T13:00:00Z", ended_at: null, labor_rate: null },
    ],
    memberships: [{ company_id: CO, user_id: "u1", labor_rate: 50 }],
    expenses: [{ company_id: CO, job_id: "j20", amount: "200.00", in_line_costs: false }, { company_id: CO, job_id: "j20", amount: "640.00", in_line_costs: true }],
    job_materials: [{ company_id: CO, job_id: "j20", service_id: "s-rock", name: "Rock", unit: "ton", quantity: 3 }],
    // The row itself: offered again, with what was agreed kept.
    job_pay: [{ company_id: CO, job_id: "j20", status: "offered", total: 6500, paid_amount: null, accepted_snapshot: { total: 7500 } }],
    job_pay_costs: [{ company_id: CO, job_id: "j20", amount: 7500, payees: 1 }],
    job_profit_alerts: [],
  });

  it("comes to the same cost and the same margin, sub pay included", async () => {
    const t = job20();
    const { db } = fakeDb(t, [], []);
    const [checked] = await costJobs(db, CO, ["j20"]);
    // The job page: the same rows as it reads them (its time, the rates the server gives it, the
    // database's sum of the pay, its expenses and logged materials), through the same function.
    const page = costJobRows({
      price: 10000,
      lines: t.jobs![0]!.lines as never,
      time: t.time_entries!.map((e) => ({ id: e.id as string, started_at: e.started_at as string, ended_at: e.ended_at as string | null })),
      rates: await timeRates(db, CO, { job_ids: ["j20"] }),
      pay: t.job_pay_costs!.map((p) => ({ amount: p.amount as number, payees: p.payees })),
      expenses: t.expenses!.map((e) => ({ amount: e.amount as string, in_line_costs: e.in_line_costs as boolean })),
      logged: t.job_materials as never,
    });
    expect(checked!.cost).toEqual(page);
    // And what that is: the sub at the $7,500 agreed, the rock as logged with its labor estimate left
    // out (3 tons at $350, and the $200 line), 8 hours at $50, the $200 expense.
    expect(page).toMatchObject({ crew: 7500, labor: 400, expenses: 200, expenses_in_lines: 640, materials: 1250, cost: 9350, margin: 6.5 });
  });

  it("keeps a job with a re-offered sub price below the line, and tells nobody again when the sub answers", async () => {
    const t = job20();
    t.job_profit_alerts = [{ company_id: CO, job_id: "j20", below: true }];
    const { db, recorded } = fakeDb(t, [{ company_id: CO, line: 10, sweep: false }], [{ job_id: "j20", changed_at: "2026-11-13T10:00:00Z" }]);
    expect(await checkJobProfits(db)).toMatchObject({ checked: 1, told: 0 });
    // Still below, as the job page says: it never left the list, so there's nothing to tell twice.
    expect((recorded[0]!.args.p_checks as Row[])[0]).toMatchObject({ job_id: "j20", below: true, tell: false, margin: 6.5 });
  });
});

describe("the hourly job profit check", () => {
  it("tells the office about a one-off job that went below the line, in the job page's numbers", async () => {
    const { db, recorded, swept } = fakeDb(tables(), [{ company_id: CO, line: 20, sweep: false }], [{ job_id: "j12", changed_at: "2026-11-13T10:00:00.123456+00:00" }, { job_id: "j13", changed_at: null }, { job_id: "w1", changed_at: null }]);
    expect(await checkJobProfits(db)).toEqual({ companies: 1, checked: 3, told: 1, listed: 0, failed: 0 });
    const checks = recorded[0]!.args.p_checks as Row[];
    expect(checks.find((c) => c.job_id === "j12")).toEqual({
      job_id: "j12", changed_at: "2026-11-13T10:00:00.123456+00:00", below: true, tell: true, margin: 8, title: "Job #12 for Maria Lopez is at 8% profit, below your 20%",
    });
    // Nothing spent on #13 yet, and a repeating job isn't held to the line.
    expect(checks.find((c) => c.job_id === "j13")).toMatchObject({ below: false, tell: false });
    expect(checks.find((c) => c.job_id === "w1")).toMatchObject({ below: false, tell: false });
    expect(swept).toEqual([]);
  });

  it("doesn't tell again about a job already below", async () => {
    const t = tables();
    t.job_profit_alerts = [{ company_id: CO, job_id: "j12", below: true }];
    const { db, recorded } = fakeDb(t, [{ company_id: CO, line: 20, sweep: false }], [{ job_id: "j12", changed_at: "2026-11-13T10:00:00Z" }]);
    expect((await checkJobProfits(db)).told).toBe(0);
    expect((recorded[0]!.args.p_checks as Row[])[0]).toMatchObject({ below: true, tell: false });
  });

  it("only lists the jobs below right after the line changes, and finishes the sweep", async () => {
    const { db, recorded, swept } = fakeDb(tables(), [{ company_id: CO, line: 20, sweep: true }], [{ job_id: "j12", changed_at: null }]);
    expect(await checkJobProfits(db)).toMatchObject({ told: 0, listed: 1 });
    expect((recorded[0]!.args.p_checks as Row[])[0]).toMatchObject({ below: true, tell: false });
    expect(swept).toEqual([CO]);
  });

  it("looks at every job of a first look, past the 1,000 one request brings", async () => {
    // 2,300 open jobs when the margin is set: none with anything spent, so none below.
    const many = Array.from({ length: 2300 }, (_, i) => ({ job_id: `j${String(i).padStart(4, "0")}`, changed_at: null }));
    const t = tables();
    t.jobs = many.map((j, i) => ({ id: j.job_id, company_id: CO, number: 100 + i, kind: "one_off", status: "active", client: null, financials: { contract_total: 500 }, lines: [] }));
    const { db, recorded, pages } = fakeDb(t, [{ company_id: CO, line: 20, sweep: true }], many);
    expect(await checkJobProfits(db)).toMatchObject({ checked: 2300, told: 0, failed: 0 });
    // Three pages of jobs (1,000, 1,000 and 300), each job recorded once.
    expect(pages.filter((p) => p === "profit_alert_jobs")).toHaveLength(3);
    const checked = recorded.flatMap((r) => (r.args.p_checks as Row[]).map((c) => c.job_id));
    expect(checked).toHaveLength(2300);
    expect(new Set(checked).size).toBe(2300);
  });

  it("keeps a margin too large to store as the nearest one that fits, so the company's check doesn't stall", async () => {
    // A job priced at a cent with $1,920 of costs: about nineteen million percent under.
    const t = tables();
    (t.jobs![0] as Row).financials = { contract_total: "0.01" };
    t.expenses!.push({ company_id: CO, job_id: "j12", amount: "1000.00", in_line_costs: false });
    const { db, recorded } = fakeDb(t, [{ company_id: CO, line: 20, sweep: false }], [{ job_id: "j12", changed_at: "2026-11-13T10:00:00Z" }]);
    expect(await checkJobProfits(db)).toMatchObject({ checked: 1, failed: 0 });
    expect((recorded[0]!.args.p_checks as Row[])[0]).toMatchObject({ job_id: "j12", below: true, margin: -9_999_999.9 });
    expect([keptMargin(null), keptMargin(8), keptMargin(1e12), keptMargin(-1e12)]).toEqual([null, 8, 9_999_999.9, -9_999_999.9]);
  });

  it("clears the notes of jobs that are gone", async () => {
    const { db, recorded } = fakeDb(tables(), [{ company_id: CO, line: 20, sweep: false }], [{ job_id: "gone", changed_at: "2026-11-13T10:00:00Z" }]);
    await checkJobProfits(db);
    expect(recorded[0]!.args.p_checks).toEqual([{ job_id: "gone", changed_at: "2026-11-13T10:00:00Z", below: false, tell: false, margin: null, title: null }]);
  });
});
