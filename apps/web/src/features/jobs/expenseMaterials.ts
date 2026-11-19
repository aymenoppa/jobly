/**
 * A supplier invoice in Add expense, for the office with job costs: how its lines count in the
 * job's costs when they're logged as materials used, and whether the same receipt looks to be in
 * already. Worked out here from what the form shows, anew each time anything on it changes, so the
 * answer is the same whichever boxes were ticked or unticked on the way.
 *
 * The rule (20261113001670_supplier_invoices_count_once.sql keeps it):
 *
 *   A material logged against the job's own estimate counts through the job's line items, at the
 *   line item's cost, in place of the estimate. So that line's amount on the invoice is "already in
 *   the job's line item costs" and isn't counted again.
 *
 *   Everything else on the invoice counts as an expense: a line that isn't a material on the job
 *   (delivery, a fuel surcharge), a material that's on the price list but not on this job's
 *   estimate (logged for the record; nothing on the job's lines stands for it), the tax, and
 *   whatever the lines don't account for.
 *
 *   A material the crew already logged tickets for isn't logged again: its quantity is on the job
 *   once. Its line still counts through the line items, by those tickets, so it isn't an expense
 *   either. Unless the office says this invoice is for more of it ("Log it too").
 *
 *   With "Also log" off nothing is logged and nothing is taken off the expense for it. The office's
 *   own tick, "Already in the job's line item costs", is the whole expense's, as it always was.
 *
 * So an invoice never counts twice (its logged lines as materials and again as an expense) and never
 * drops out (an expense marked as in the line items with no material behind it because a box was
 * unticked later).
 */
import { lineAmount, type MaterialCandidate, type ReceiptLine } from "@jobly/core/receipts";
import { formatDate, formatMoneyCents } from "@/lib/format";
import { t } from "@/lib/i18n";

/** A material already logged on the job (job_materials), before this invoice. */
export interface LoggedBefore {
  service_id: string | null;
  unit: string;
  quantity: number | string;
}

/** A line to log as a material used (save_read_expense's p_materials). */
export interface MaterialToLog {
  service_id: string | null;
  name: string;
  unit: string;
  quantity: number;
  ticket: string | null;
}

/** What happens to one line of the invoice. */
export interface LinePlan {
  /** What it's logged as: null when it isn't a material on the job, or has no quantity to log. */
  candidate: MaterialCandidate | null;
  /** Its amount on the invoice, when it shows one. */
  amount: number | null;
  /** How much of the same item, in the same unit, the job had logged before this invoice. */
  already: number;
  /** Logged as a material used when the expense is saved. */
  log: boolean;
  /** Its amount counts through the job's line items, so it comes off what counts as an expense. */
  inLines: boolean;
}

export interface MaterialsPlan {
  lines: LinePlan[];
  toLog: MaterialToLog[];
  /** How much of the expense is already in the job's line item costs: 0 to the whole amount. */
  inLineAmount: number;
  /** How much counts as an expense. */
  counted: number;
}

const cents = (n: number) => Math.round(n * 100) / 100;
const same = (a: string | null | undefined, b: string | null | undefined) => (a ?? "").trim().toLowerCase() === (b ?? "").trim().toLowerCase();

/**
 * The plan for an invoice's lines. `choices[i]` is the candidate line i is logged as (-1: not a
 * material on this job); `again[i]` says to log a line whose material already has tickets on the
 * job; `ticked` is the office's own "Already in the job's line item costs" for the whole expense.
 */
export function materialsPlan(input: {
  lines: readonly ReceiptLine[];
  candidates: readonly MaterialCandidate[];
  choices: readonly number[];
  again?: readonly boolean[];
  before?: readonly LoggedBefore[];
  logMaterials: boolean;
  amount: number;
  ticked: boolean;
  ticket?: string | null;
}): MaterialsPlan {
  const amount = Number.isFinite(input.amount) && input.amount > 0 ? cents(input.amount) : 0;
  const lines = input.lines.map((line, i): LinePlan => {
    const candidate = line.quantity !== null && line.quantity > 0 ? input.candidates[input.choices[i] ?? -1] ?? null : null;
    const already = candidate
      ? (input.before ?? []).filter((m) => m.service_id === candidate.service_id && same(m.unit, candidate.unit)).reduce((sum, m) => sum + Number(m.quantity), 0)
      : 0;
    // Tickets for it are on the job already: once is enough, unless the office says this is more of it.
    const skip = already > 0 && !input.again?.[i];
    const log = input.logMaterials && candidate !== null && !skip;
    // Through the job's lines: logged now against its estimate, or on the job already by the crew's tickets.
    const inLines = input.logMaterials && candidate !== null && candidate.estimated;
    return { candidate, amount: lineAmount(line), already, log, inLines };
  });
  const toLog = lines.flatMap((p, i) =>
    p.log && p.candidate ? [{ service_id: p.candidate.service_id, name: p.candidate.name, unit: p.candidate.unit, quantity: input.lines[i]!.quantity!, ticket: input.ticket ?? null }] : [],
  );
  const fromLines = cents(lines.reduce((sum, p) => sum + (p.inLines ? Math.max(p.amount ?? 0, 0) : 0), 0));
  const inLineAmount = input.ticked ? amount : Math.min(fromLines, amount);
  return { lines, toLog, inLineAmount, counted: cents(amount - inLineAmount) };
}

const qty = (n: number) => new Intl.NumberFormat("en-US", { maximumFractionDigits: 3 }).format(n);

/** Under a line whose material already has tickets on the job: what's there, and what happens to this line. */
export function alreadyLoggedNote(plan: LinePlan): string | null {
  if (!plan.candidate || !(plan.already > 0)) return null;
  const there = `${qty(plan.already)} ${plan.candidate.unit} of ${plan.candidate.name} ${plan.already === 1 ? "is" : "are"} already logged on this job`;
  return plan.log ? `${there}. This line is logged on top of that.` : `${there}, so this line isn't logged again. Tick "Log it too" if this invoice is for more.`;
}

/**
 * How the expense will count in the job's costs, said before it's saved. Null when nothing is being
 * logged and the office hasn't ticked the whole expense (it counts as any expense does).
 */
export function planWords(plan: MaterialsPlan, options: { logMaterials: boolean; ticked: boolean }): string | null {
  if (options.ticked) return "All of it is marked as already in the job's line item costs, so job costing won't count this expense on top of them.";
  if (!options.logMaterials) return null;
  const missing = plan.lines.filter((p) => p.inLines && p.amount === null).length;
  const noAmount = missing ? ` ${missing === 1 ? "One line" : `${missing} lines`} logged against the estimate ${missing === 1 ? "shows" : "show"} no amount on the invoice, so ${missing === 1 ? "it stays" : "they stay"} in the expense: check the two below.` : "";
  if (plan.inLineAmount <= 0) {
    return `None of what's logged is on this job's estimate, so the whole ${formatMoneyCents(plan.counted)} counts as an expense.${noAmount}`;
  }
  if (plan.counted <= 0) {
    return `In job costing, all ${formatMoneyCents(plan.inLineAmount)} counts through the job's line items (the materials on its estimate, at the line items' cost), so the expense isn't counted on top of them.${noAmount}`;
  }
  return `In job costing, ${formatMoneyCents(plan.inLineAmount)} counts through the job's line items (the materials on its estimate, at the line items' cost) and the other ${formatMoneyCents(plan.counted)} counts as an expense. It's saved as two expenses with the same receipt, so neither part is counted twice.${noAmount}`;
}

// ---------------------------------------------------------------------------------------------
// The same receipt twice
// ---------------------------------------------------------------------------------------------

/** An expense that's in already, as the check reads it. */
export interface KnownExpense {
  id: string;
  vendor: string | null;
  amount: number | string;
  /** What its whole receipt came to, when it's one part of one. */
  receipt_total?: number | string | null;
  incurred_on: string;
  invoice_number?: string | null;
  receipt_path?: string | null;
  job?: { number: number | null } | null;
}

/** What's about to be saved. */
export interface NewReceipt {
  vendor: string | null;
  total: number;
  date: string;
  invoice_number: string | null;
}

/**
 * The expenses that look like the receipt being saved: the same invoice number (from the same
 * vendor, when both say who), or the same vendor, day and total. A receipt saved as two expenses is
 * one receipt, listed once.
 */
export function lookalikes(next: NewReceipt, known: readonly KnownExpense[]): KnownExpense[] {
  const total = (e: KnownExpense) => cents(Number(e.receipt_total ?? e.amount));
  const hits = known.filter((e) => {
    const sameVendor = same(e.vendor, next.vendor);
    if (next.invoice_number?.trim() && same(e.invoice_number, next.invoice_number) && (sameVendor || !e.vendor?.trim() || !next.vendor?.trim())) return true;
    return Boolean(next.vendor?.trim()) && sameVendor && e.incurred_on === next.date && total(e) === cents(next.total);
  });
  const seen = new Set<string>();
  return hits.filter((e) => {
    const key = e.receipt_total != null ? `${e.receipt_path ?? ""}|${(e.vendor ?? "").trim().toLowerCase()}|${e.incurred_on}|${total(e)}` : e.id;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/**
 * What's asked before saving a receipt that looks to be in already. Null when nothing looks like it.
 * A crew member adding their own receipt twice sees it too, so it's said in their language.
 */
export function sameReceiptQuestion(matches: readonly KnownExpense[]) {
  if (!matches.length) return null;
  const one = (e: KnownExpense) =>
    t("{vendor}, {total} on {date}", { vendor: e.vendor?.trim() || t("An expense"), total: formatMoneyCents(Number(e.receipt_total ?? e.amount)), date: formatDate(e.incurred_on) }) +
    (e.invoice_number ? t(", invoice {number}", { number: e.invoice_number }) : "") +
    (e.job?.number != null ? t(", on job #{number}", { number: e.job.number }) : "");
  const more = matches.length > 3 ? t("; and {count} more", { count: matches.length - 3 }) : "";
  return {
    title: t("This looks like a receipt that's already in"),
    body: `${matches.slice(0, 3).map(one).join("; ")}${more}. ${t("Saving this one as well would count it twice.")}`,
    confirmLabel: t("Save it anyway"),
    cancelLabel: t("Go back"),
  };
}
