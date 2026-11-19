/**
 * Record a refund of a payment taken by hand (cash, a check): a negative payment on the invoice,
 * under the person's own rules, which puts the balance back up by what went back. With `takeOff`
 * (the dialog's "Take it off the invoice too") that balance is then written off, exactly as the
 * refund through Stripe does it (apps/api/src/routes/autopay.ts): only when all that's owed now came
 * from this refund. Other money still owed is still asked for, and `still_owed` says how much, the
 * refunded part with it.
 *
 * A paid invoice past its due date that's owed again reads past due at once, but the database
 * raises no past-due event that day and counts a late fee's grace days from then
 * (20261113000430_owed_again_without_chasing.sql): owedAgainNote says so before it's done.
 */
import { toCents } from "@jobly/core/money";
import { supabase, unwrap } from "@/lib/api";
import { formatMoneyCents } from "@/lib/format";
import { refundable } from "./refunds";

/** The statuses an invoice is owed in (the write-off rules' own list). */
const OWED = ["sent", "partially_paid", "overdue"];

export interface RefundRecord {
  companyId: string;
  invoice: { id: string; client_id: string };
  payment: { amount: number; method: string };
  amount: number;
  receivedAt: string;
  notes: string | null;
  takeOff: boolean;
}

export interface RefundResult {
  written_off: boolean;
  /** Over 0 only when it was to come off the invoice and other money is still owed, so nothing was written off. */
  still_owed: number;
}

export async function recordRefund(r: RefundRecord): Promise<RefundResult> {
  const db = supabase();
  // Check again against the latest payments, in case a refund was just recorded elsewhere.
  const latest = unwrap(await db.from("payments").select("amount, method, processor").eq("invoice_id", r.invoice.id));
  const now = refundable(r.payment, latest);
  if (r.amount > now + 0.005) throw new Error(now > 0 ? `Only ${formatMoneyCents(now)} of this payment is left to refund.` : "This payment has already been refunded.");
  const refunded = toCents(r.amount);
  unwrap(
    await db.from("payments").insert({
      company_id: r.companyId,
      invoice_id: r.invoice.id,
      client_id: r.invoice.client_id,
      amount: -refunded / 100,
      method: r.payment.method as "check",
      received_at: r.receivedAt,
      notes: r.notes ? `Refund: ${r.notes}` : "Refund",
    }),
  );
  if (!r.takeOff) return { written_off: false, still_owed: 0 };
  // The refund is recorded either way; a balance it couldn't take off can still be written off from the menu.
  const { data: invoice } = await db.from("invoices").select("status, balance_due").eq("id", r.invoice.id).maybeSingle();
  const owed = toCents(invoice?.balance_due ?? 0);
  if (!invoice || !OWED.includes(invoice.status) || owed <= 0) return { written_off: false, still_owed: 0 };
  if (owed > refunded) return { written_off: false, still_owed: owed / 100 };
  const { error } = await db.from("invoices").update({ status: "written_off" }).eq("id", r.invoice.id);
  return { written_off: !error, still_owed: 0 };
}

/**
 * What the office is told after a refund recorded by hand: `success` is the toast, and `note` is
 * said beside it when the box was ticked but the balance stayed (other money is still owed, or the
 * write-off didn't go through).
 */
export function refundToasts(result: RefundResult, takeOff: boolean): { success: string; note: { title: string; description?: string } | null } {
  if (takeOff && result.still_owed > 0) {
    return {
      success: "Refund recorded",
      note: {
        title: "The balance wasn't taken off",
        description: `${formatMoneyCents(result.still_owed)} is still owed on this invoice, including the refunded part. Write it off from the invoice menu if you don't want it collected.`,
      },
    };
  }
  return { success: takeOff && result.written_off ? "Refund recorded and taken off the invoice" : "Refund recorded", note: null };
}

/**
 * Said before the office puts a balance back on a paid invoice whose due date has passed (a payment
 * removed, a refund that stays on the invoice): what happens next. Null when it wouldn't be past
 * due: not paid now, not due yet, or nothing would be owed after.
 */
export function owedAgainNote(invoice: { status: string; due_on: string | null; balance_due: number | string }, back: number, today: string): string | null {
  if (invoice.status !== "paid" || !invoice.due_on || invoice.due_on >= today) return null;
  if (toCents(invoice.balance_due) + toCents(back) <= 0) return null;
  return "This invoice will show as past due. The client isn't reminded today.";
}
