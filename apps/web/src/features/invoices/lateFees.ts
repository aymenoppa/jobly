/**
 * What the invoice page offers about late fees (20261113000420_late_fee_off_for_an_invoice.sql):
 * Remove late fee on an invoice that has one, the "No late fee on this invoice" tick on one that
 * hasn't had one, and what it says once a fee was taken off. The database decides the same.
 */

interface FeeInvoice {
  kind: string;
  status: string;
  late_fee_at: string | null;
  /** Late fees are off for it. Missing from a page loaded before the column was there. */
  no_late_fee?: boolean | null;
  lines: ReadonlyArray<{ kind?: string | null }>;
}

export interface LateFeeControls {
  /** It has a late fee line that can come off. */
  remove: boolean;
  /** The tick is shown: late fees could still go on it, or were turned off before one did. */
  tick: boolean;
  /** Said in place of the tick once a fee was removed: it never gets another. */
  note: string | null;
}

/**
 * `feesOn`: the business charges late fees (Settings → Company). `fromStripe`: made in Stripe,
 * which never gets one here. A void or written-off invoice is left as it is; a paid one or a
 * deposit never gets a fee, so there's nothing to tick.
 */
export function lateFeeControls(invoice: FeeInvoice, { feesOn, fromStripe }: { feesOn: boolean; fromStripe: boolean }): LateFeeControls {
  const locked = invoice.status === "void" || invoice.status === "written_off";
  const hasFee = invoice.lines.some((l) => l.kind === "late_fee");
  const off = Boolean(invoice.no_late_fee);
  // Taken off: the fee went on once (late_fee_at) and its line is gone.
  const removed = !hasFee && off && Boolean(invoice.late_fee_at);
  const couldGetOne = !hasFee && !invoice.late_fee_at && invoice.status !== "paid" && invoice.kind !== "deposit" && !fromStripe;
  return {
    remove: hasFee && !locked,
    tick: !locked && couldGetOne && (feesOn || off),
    note: removed ? "Late fee removed. No late fee goes on this invoice again." : null,
  };
}
