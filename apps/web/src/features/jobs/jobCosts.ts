/**
 * The job page's costs: core's jobCost (packages/core/src/reports.ts), the one calculation Finance →
 * Profit and Services, AI assistants and the office's job profit alerts use too, with the notes the
 * job costing card shows under it. Line items count at cost, with labor (time at its rates), sub and
 * crew pay (agreed, done or paid: public.job_pay_costs) and expenses. Once a job has labor of its own
 * that costs something (time on it at a rate, or sub and crew pay), its line items count without the
 * labor estimate their cost has in it, so that labor isn't counted twice. Time that costs nothing yet
 * (no rate set, or a clock still running) leaves the estimate in.
 *
 * Materials aren't counted twice either. A material logged against one of the job's lines (a load
 * ticket for the tons a line estimated) counts at the logged amount in place of the line's estimate
 * (materialUse), and an expense marked as already in the line items' costs (the supplier's invoice
 * for materials the estimate covers) isn't added on top of them.
 */
import { costJobRows, jobCost, type CostedLine, type CostedMaterial, type JobCost, type JobCostRows } from "@jobly/core/reports";
import { formatMoneyCents } from "@/lib/format";

export interface JobCostInput {
  contract: number;
  lines: readonly CostedLine[];
  /** Time on the job at its rates. */
  labor: number;
  /** Expenses that count: those not marked as already in the line items' costs. */
  expenses: number;
  /** Expenses marked as already in the line items' costs. */
  expensesInLines?: number;
  /** Materials logged on the job (job_materials). */
  logged?: readonly CostedMaterial[];
  /** public.job_pay_costs for the job: nothing when it has none. */
  crewPay: ReadonlyArray<{ amount: number | string | null; payees: number }>;
  /**
   * Extra work on a repeating job's visits (core costedExtras): what it's billed at, on top of the
   * job's price, and its lines, costed as the job's are.
   */
  extras?: { price: number; lines: readonly CostedLine[] };
}

/** The rule for logged materials, said on the Materials card and under the job's costs. */
export const LOGGED_MATERIALS_RULE = "Once a material on this job's line items is logged, job costing counts the amount logged, at the line's cost, in place of the estimate.";

export function jobCosts(input: JobCostInput) {
  const inLines = input.expensesInLines ?? 0;
  // The page has its expenses summed already: as rows, the ones that count and the ones already in the lines.
  const expenses = [...(input.expenses ? [{ amount: input.expenses }] : []), ...(inLines ? [{ amount: inLines, in_line_costs: true }] : [])];
  return described(jobCost({ price: input.contract, lines: input.lines, labor: input.labor, crewPay: input.crewPay, expenses, logged: input.logged, extras: input.extras }));
}

/**
 * The job page's costs from the job's own rows as the page reads them: core's costJobRows, the
 * function the hourly profit check costs the job with too (apps/api/src/services/profitAlerts.ts),
 * so the page's "below your margin" and the check's notice are one answer.
 */
export function jobPageCosts(rows: JobCostRows) {
  return described(costJobRows(rows));
}

/** A job's costs as the costing card shows them, with the notes under it. */
function described(c: JobCost) {
  const inLines = c.expenses_in_lines;
  const compared = c.material_rows.filter((r) => r.estimated !== null);
  return {
    materials: c.materials,
    leftOut: c.left_out,
    labor: c.labor,
    crew: c.crew,
    expenses: c.expenses,
    total: c.cost,
    profit: c.profit,
    margin: c.margin === null ? null : Math.round(c.margin),
    /** What the extra work is billed at: counted with the price, and shown on a line of its own. */
    extras: c.extras,
    actualLabor: c.actual_labor,
    /** Whether anything has been spent on the job yet: a profit alert waits for it. */
    hasActualCosts: c.has_actual_costs,
    /** Each logged material against the lines' estimate for it (Materials used shows them). */
    materialRows: c.material_rows,
    /** What logged materials changed the line item costs by. */
    materialAdjustment: c.material_adjustment,
    /** The one line under the costs when line items count materials only. */
    note: c.actual_labor && c.left_out > 0
      ? `Line item costs count materials only, since this job has its own labor: the ${formatMoneyCents(c.left_out)} of labor estimated in them isn't counted twice.`
      : null,
    /** Under the costs when logged materials stand in for a line's estimate. */
    materialNote: compared.length
      ? `Line item costs count ${compared.length === 1 ? compared[0]!.name : `${compared.length} materials`} as logged, not as estimated: ${c.material_adjustment === 0 ? "the same as" : `${formatMoneyCents(Math.abs(c.material_adjustment))} ${c.material_adjustment > 0 ? "over" : "under"}`} the estimate.`
      : null,
    /** Under the costs when some expenses are left out as already in the line items. */
    expenseNote: inLines > 0 ? `${formatMoneyCents(inLines)} of expenses are marked as already in the line item costs, so they aren't counted again.` : null,
  };
}
