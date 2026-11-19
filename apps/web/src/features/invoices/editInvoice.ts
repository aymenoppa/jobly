/**
 * Edit invoice: changing a sent invoice's lines in place, payments and all, through the database's
 * edit_invoice (20261113000440_edit_sent_invoices.sql). These are the parts of the edit screen that
 * can be worked out without it: which lines an edit takes and which stay, the rows being typed and
 * the lines they send, and what's said about the result. The figures themselves are the database's
 * (its preview), never added up here.
 */
import { formatMoneyCents } from "@/lib/format";

export interface InvoiceLine {
  id: string;
  name: string;
  description: string | null;
  quantity: number | string;
  unit: string;
  unit_price: number | string;
  taxable: boolean;
  sort: number;
  service_id?: string | null;
  /** minimum: the Minimum charge line; late_fee: a late fee. */
  kind?: string | null;
  /** A promo code's discount line. */
  discount_quote_id?: string | null;
}

const CREDIT = /^Less (deposit|progress billing) \(invoice #\d+\)$/;

/**
 * Why a line stays as it is through an edit (private.invoice_line_locked), or null for a line the
 * edit takes: a late fee, the Minimum charge line, a promo code's discount, and a final invoice's
 * credit for one of the job's deposit or progress invoices.
 */
export function lockedReason(line: Pick<InvoiceLine, "name" | "unit_price" | "kind" | "discount_quote_id">): string | null {
  if (line.kind === "late_fee") return "Use Remove late fee to take it off.";
  if (line.kind) return "The minimum charge stays as it was sent.";
  if (line.discount_quote_id) return "A promo code's discount stays as it was sent.";
  if (Number(line.unit_price) < 0 && CREDIT.test(line.name)) return "It takes off what another of the job's invoices billed.";
  return null;
}

/** A line as it's typed in the edit screen. `id` is null for one being added. */
export interface EditRow {
  key: string;
  id: string | null;
  name: string;
  description: string;
  quantity: string;
  unit: string;
  unit_price: string;
  taxable: boolean;
}

const inOrder = <T extends { sort: number }>(lines: readonly T[]) => [...lines].sort((a, b) => Number(a.sort) - Number(b.sort));

/** The invoice's lines an edit takes, in order, ready to type over. */
export function editRows(lines: readonly InvoiceLine[]): EditRow[] {
  return inOrder(lines)
    .filter((l) => !lockedReason(l))
    .map((l) => ({ key: l.id, id: l.id, name: l.name, description: l.description ?? "", quantity: String(Number(l.quantity)), unit: l.unit, unit_price: Number(l.unit_price).toFixed(2), taxable: l.taxable }));
}

/** The lines that stay, in order, each with why. */
export function lockedLines<T extends InvoiceLine>(lines: readonly T[]): Array<{ line: T; reason: string }> {
  return inOrder(lines).flatMap((line) => {
    const reason = lockedReason(line);
    return reason ? [{ line, reason }] : [];
  });
}

/** A new empty row; new work is taxed as the invoice's other lines are (untaxed when none of them is). */
export function newRow(rows: readonly EditRow[], key: string): EditRow {
  return { key, id: null, name: "", description: "", quantity: "1", unit: "ea", unit_price: "", taxable: rows.length ? rows.some((r) => r.taxable) : true };
}

const NUMBER = /^-?\d*\.?\d+$/;

/** What stops the rows being sent, in the screen's words, or null. `locked`: how many lines stay whatever is typed. */
export function rowsProblem(rows: readonly EditRow[], locked = 0): string | null {
  if (!rows.length && !locked) return "An invoice needs at least one line.";
  if (rows.some((r) => !r.name.trim())) return "Give every line a name.";
  if (rows.some((r) => !NUMBER.test(r.quantity.trim()))) return "Enter how many for every line.";
  if (rows.some((r) => !NUMBER.test(r.unit_price.trim()))) return "Enter a price for every line.";
  return null;
}

/** The rows as edit_invoice takes them: in order, an existing line by its id. */
export function rowsToLines(rows: readonly EditRow[]) {
  return rows.map((r) => ({
    ...(r.id ? { id: r.id } : {}),
    name: r.name.trim(),
    description: r.description.trim() || null,
    quantity: Number(r.quantity),
    unit: r.unit.trim() || "ea",
    unit_price: Math.round(Number(r.unit_price) * 100) / 100,
    taxable: r.taxable,
  }));
}

/** What edit_invoice answers (a preview's is what the invoice would come to). */
export interface EditResult {
  status: string;
  total: number;
  amount_paid: number;
  balance_due: number;
  /** How many lines were added, removed or changed in what they say. */
  changed: number;
  old_total: number;
  old_status: string;
}

/**
 * What the edit screen says the invoice comes to: the new total (and what it was, when it moved),
 * what's been paid, and what that leaves. Paid in full by the change, or owed again by it, it says so.
 */
export function resultWords(result: EditResult): string {
  const total = Number(result.total);
  const paid = Number(result.amount_paid);
  const balance = Number(result.balance_due);
  const moved = total !== Number(result.old_total);
  const parts = [`Total ${formatMoneyCents(total)}${moved ? ` (was ${formatMoneyCents(Number(result.old_total))})` : ""}`];
  if (paid !== 0) parts.push(`${formatMoneyCents(paid)} paid`);
  if (result.status === "paid" && result.old_status !== "paid") parts.push("paid in full");
  else if (balance > 0) parts.push(`${formatMoneyCents(balance)} ${result.old_status === "paid" ? "now owed" : "to pay"}`);
  return parts.join(" · ");
}

/**
 * Whether Edit invoice is offered, and what holds it back for now. Not on a draft (its lines are
 * edited on the page), a void or written-off invoice, or one made in Stripe (changed there). While
 * the card is being charged or a bank payment is on its way it waits, since the client is paying
 * the amount as it stands. The database refuses the same, and says why for anything it knows that
 * the page doesn't (a deposit the job's final invoice has taken off).
 */
export function editOffer(invoice: { status: string }, state: { fromStripe: boolean; charging: boolean; bankOnItsWay: boolean }): { offered: boolean; waits: string | null } {
  if (["draft", "void", "written_off"].includes(invoice.status) || state.fromStripe) return { offered: false, waits: null };
  if (state.charging) return { offered: true, waits: "The card is being charged right now. Try again in a few minutes." };
  if (state.bankOnItsWay) return { offered: true, waits: "A bank payment for this invoice is on its way. Edit it once that clears or bounces." };
  return { offered: true, waits: null };
}
