/**
 * Who finishes the paperwork on site, and how much of the money they see. The team adds work from
 * the price list without seeing a price (to a one-off job, or to this visit of a repeating one); making the invoice, its total, sending it and recording
 * cash or check are for owners, admins and office with the invoices area, as on the job page. The
 * database decides the same (20261106000700_field_lines.sql, and the invoices and payments rules).
 */
import { can, hasRole, type Session } from "@/lib/session";

type Who = Pick<Session, "role" | "permissions">;

/** Adds work to a visit's job from the price list: the team, never a sub (the prices are the client's). */
export const addsWork = (who: Who) => who.role !== "subcontractor";

/** A job that takes work added on site (add_field_line): one that's still open, one-off or repeating. */
export const takesWork = (job: { kind: string; status: string }) => job.status === "active" || job.status === "requires_invoicing";

/**
 * Where work added on site goes. On a one-off job it's a line on the job. A repeating job's lines
 * bill every visit, so there it's extra work on this visit alone, billed once with it
 * (20261113000900_visit_extras.sql), and not once the visit is on an invoice.
 */
export const addsToVisit = (job: { kind: string }) => job.kind === "recurring";

/** Makes the job's invoice on site, sees its total, sends it and records cash or check. */
export const takesMoney = (who: Who) => hasRole(who, "admin", "office") && can(who, "invoices");

/**
 * The invoice a visit's Create invoice makes: what the job page's Create invoice offers first. A
 * one-off job's final invoice, or a per-visit job's finished visits. Null for a fixed price, which
 * the office bills by the month.
 */
export function fieldInvoiceKind(job: { kind: string; pricing: string | null }): "standard" | "visits" | null {
  if (job.kind !== "recurring") return "standard";
  return job.pricing === "fixed" ? null : "visits";
}
