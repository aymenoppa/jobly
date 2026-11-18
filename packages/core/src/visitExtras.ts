/**
 * Extra work on one visit of a repeating job (supabase/migrations/20261113000900_visit_extras.sql):
 * mulch, an aeration, a storm cleanup. It isn't a job line, so the job's price for a visit doesn't
 * change; it's billed once, on the invoice that bills its visit, and only when the visit is done.
 * The database decides all of that (create_invoice_for_job); these say it on screen.
 */
import { billingAnswers, type JobBilling } from "./jobBilling";
import { lineTotal, toCents } from "./money";

export interface VisitExtra {
  id: string;
  /** Null once its visit was deleted (visit_was_on keeps the day). */
  visit_id: string | null;
  name: string;
  quantity: number | string;
  unit: string;
  unit_price: number | string;
  unit_cost?: number | string | null;
  unit_labor_cost?: number | string | null;
  invoice_id: string | null;
  visit_was_on?: string | null;
  added_in_field_at?: string | null;
}

/** The fields of its visit an extra's state goes by. */
export interface ExtraVisit {
  id: string;
  status: string;
  invoice_id?: string | null;
}

/**
 * Where an extra stands: on an invoice; ready (its visit is done and not invoiced yet); waiting
 * for its visit to be done; or not billed, because its visit was cancelled or deleted.
 */
export type ExtraState = "invoiced" | "ready" | "waiting" | "not_billed";

export function extraState(extra: Pick<VisitExtra, "visit_id" | "invoice_id">, visit: ExtraVisit | null | undefined): ExtraState {
  if (extra.invoice_id) return "invoiced";
  if (!extra.visit_id || !visit || visit.status === "cancelled") return "not_billed";
  return visit.status === "completed" ? "ready" : "waiting";
}

/** Whether a job takes extra work on its visits: a repeating job that's still open (private.visit_extras_guard). */
export const takesExtras = (job: { kind: string; status: string }) => job.kind === "recurring" && (job.status === "active" || job.status === "requires_invoicing");

/** Whether extra work can go on a visit, or be moved to it: not cancelled, and not on an invoice yet. */
export const visitTakesExtras = (visit: Pick<ExtraVisit, "status" | "invoice_id">) => visit.status !== "cancelled" && !visit.invoice_id;

/** What extras come to before tax, each rounded to the cent as an invoice line is. */
export const extrasTotal = (extras: ReadonlyArray<Pick<VisitExtra, "quantity" | "unit_price">>) =>
  extras.reduce((sum, e) => sum + toCents(lineTotal(e.quantity, e.unit_price)), 0) / 100;

/** When an extra on a visit is billed, in a line, by how the job is billed. */
export function extraBillingHint(job: JobBilling): string {
  const a = billingAnswers(job);
  if (a?.pricing === "fixed") return a.schedule === "monthly" ? "Billed once, added to the month's invoice after the visit is done." : "Billed once, added to the next invoice after the visit is done.";
  if (a?.schedule === "monthly") return "Billed once, on the month's invoice with this visit.";
  return "Billed once, on this visit's invoice.";
}

/** An extra's state in a few words, for a list: "On invoice #12", "Ready to invoice", "Billed when the visit is done", "Not billed". */
export function extraStateText(state: ExtraState, invoiceNumber?: number | string | null): string {
  if (state === "invoiced") return invoiceNumber ? `On invoice #${invoiceNumber}` : "Invoiced";
  if (state === "ready") return "Ready to invoice";
  if (state === "waiting") return "Billed when the visit is done";
  return "Not billed";
}

/** The extras on each visit, by the visit's id. */
export function extrasByVisit<E extends Pick<VisitExtra, "visit_id">>(extras: readonly E[]): Map<string, E[]> {
  const map = new Map<string, E[]>();
  for (const e of extras) if (e.visit_id) map.set(e.visit_id, [...(map.get(e.visit_id) ?? []), e]);
  return map;
}

/**
 * What the job page asks the office about: extras nobody has invoiced whose visit was cancelled or
 * deleted (`notBilled`: to put on another visit, or remove), and ones the crew added on site that
 * aren't invoiced yet (`fromField`: to look over before they are).
 */
export function extrasToReview<E extends VisitExtra>(extras: readonly E[], visits: readonly ExtraVisit[]): { notBilled: E[]; fromField: E[] } {
  const byId = new Map(visits.map((v) => [v.id, v]));
  const stateOf = (e: E) => extraState(e, e.visit_id ? byId.get(e.visit_id) : null);
  return {
    notBilled: extras.filter((e) => stateOf(e) === "not_billed"),
    fromField: extras.filter((e) => e.added_in_field_at && !e.invoice_id && stateOf(e) !== "not_billed"),
  };
}

/**
 * What the job's costing adds for extras: the price of the ones that count (not the unbilled ones
 * of a cancelled or deleted visit) and their lines, to cost as job lines are.
 */
export function costedExtras<E extends VisitExtra>(extras: readonly E[], visits: readonly ExtraVisit[]): { price: number; lines: E[] } {
  const byId = new Map(visits.map((v) => [v.id, v]));
  const lines = extras.filter((e) => extraState(e, e.visit_id ? byId.get(e.visit_id) : null) !== "not_billed");
  return { price: extrasTotal(lines), lines };
}
