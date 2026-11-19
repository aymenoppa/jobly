/**
 * Charging a client's saved card from the office: the invoice page's Charge card button and the
 * Invoices page's Charge cards list. The server queues each one as a charge the autopay task
 * makes (POST /invoices/charge), so receipts, the paid-twice guards and failures work as autopay's.
 * And what the invoice page says about a charge that waits for the office's OK, or that was never
 * made because it's over the limit for the client's bank account.
 */
import { isBankAccount } from "@jobly/core/autopay";
import { formatMoney, formatMoneyCents } from "@/lib/format";

/** A message from Stripe or the database as part of a sentence: without its full stop. */
const clause = (text: string) => text.trim().replace(/[.\s]+$/, "");

/** Whole dollars when it's a round figure ("$500"), else with cents. */
export const limitText = (amount: number) => (Number.isInteger(amount) ? formatMoney(amount) : formatMoneyCents(amount));

/**
 * Why a charge waits for the office's OK. The database asks first, whatever the amount, when the
 * invoice has visits autopay didn't queue itself or from before the client agreed, and says why
 * ("Includes visits from before autopay started"); and when it's over the company's limit, with no
 * reason given.
 */
export function approvalText(charge: { last_error: string | null }, balance: number, cap: number | null): string {
  if (charge.last_error) return `${clause(charge.last_error).replace(/^Includes /, "It includes ")}, so it waits for your OK.`;
  if (cap != null && balance > cap) return `${formatMoneyCents(balance)} is over your ${limitText(cap)} limit, so it waits for your OK.`;
  return "It waits for your OK before it's charged.";
}

/**
 * Whether there's no OK to give for a charge that waits for one: a bank account would pay it and
 * it's over the company's limit. A bank account is never charged more than its limit, by anyone
 * (the database refuses the OK too, and closes the charge at the task's next run).
 */
export const noOkForBank = (method: { type: string } | null | undefined, balance: number, cap: number | null) => isBankAccount(method?.type) && cap != null && balance > cap;

/**
 * An invoice over the limit for the client's bank account: it wasn't taken from it, by autopay or by
 * anyone's OK (the terms say so: core autopayBankText), and where the invoice is on its way to the
 * client to pay instead. `send` is the charge's send_state: waiting or sending (the server sends it
 * within a few minutes), sent, failed (with why, so the office sends it), held (the office was to
 * look at it first for another reason, `error`, so nothing went by itself), or none (the office
 * sent it first).
 */
export function bankLimitText(balance: number, limit: number, account: string, clientName: string, send: string | null, error: string | null): string {
  const why = `${formatMoneyCents(balance)} is over the ${limitText(limit)} limit, and a bank account is never charged more than its limit, so ${account} wasn't charged.`;
  if (send === "waiting" || send === "sending") return `${why} ${clientName} is being sent this invoice to pay themselves.`;
  if (send === "sent") return `${why} ${clientName} was sent this invoice to pay themselves.`;
  if (send === "failed") return `${why} It couldn't be sent to them${error ? ` (${clause(error)})` : ""}, so it's yours to send.`;
  if (send === "held") return `${why} Look it over before you send it to them to pay${error ? `: ${clause(error).replace(/^Includes /, "it includes ")}` : ""}.`;
  return `${why} It's theirs to pay themselves.`;
}

/** What the server did with each invoice (public.request_manual_charges). */
export interface ChargeResult {
  invoice_id: string;
  outcome: string;
  reason: string | null;
}

/** An unpaid invoice whose client has a card they agreed to have charged (GET /invoices/chargeable). */
export interface ChargeableInvoice {
  id: string;
  number: number;
  client_id: string;
  client_name: string;
  balance_due: number;
  due_on: string | null;
  status: string;
  card: string;
  in_progress: boolean;
  /** The charge already under way, when there is one, and the server's words for it. */
  live_status?: "charging" | "waiting_on_client" | "retrying" | "needs_approval" | "bank_clearing" | null;
  live_detail?: string | null;
}

/** The most invoices one call takes. */
export const CHARGE_CHUNK = 50;

const OUTCOMES: Record<string, string> = {
  queued: "Charging",
  no_card: "No card on file",
  not_owed: "Nothing owed",
  in_progress: "Already on its way",
  bank_limit: "Over the limit for their bank account. Send it to them to pay",
  changed: "The amount changed. Check it and try again",
  not_sent: "Not sent. Try again.",
  autopay_off: "Charging saved cards is off in Settings → Payments",
  too_small: "Too small for Stripe",
  not_found: "Invoice not found",
};

/**
 * What happened to one invoice, in plain words: the server's reason when it gives one (it knows
 * whether it's the Settings switch or the Stripe key, or a paused card), else the outcome's own.
 */
export const chargeOutcomeText = (r: Pick<ChargeResult, "outcome" | "reason">) => r.reason ?? OUTCOMES[r.outcome] ?? "Not charged";

const LIVE: Record<string, string> = {
  charging: "Charging now",
  waiting_on_client: "Waiting on the client",
  retrying: "Autopay will try it again",
  needs_approval: "Waiting for your OK",
  bank_clearing: "Bank payment on its way",
};

/** Whether a listed invoice has a charge under way already, so it can't be picked. */
export const chargeBusy = (r: ChargeableInvoice) => r.in_progress || r.live_status != null;

/** What the charge under way is doing, in plain words: the server's when it gives them, else its status's own. */
export const chargeLiveText = (r: ChargeableInvoice) => r.live_detail ?? LIVE[r.live_status ?? ""] ?? "Already on its way";

/**
 * Sends the picked invoices CHARGE_CHUNK at a time, each with the balance the office saw, and says
 * what happened to each. When a later chunk fails, the ones sent keep their results and the rest say
 * they weren't sent (with the error); when the first fails nothing went, so it throws for the form.
 */
export async function chargeInChunks(rows: ChargeableInvoice[], post: (body: { invoices: Array<{ id: string; amount: number }> }) => Promise<{ results: ChargeResult[] }>) {
  const results = new Map<string, ChargeResult>();
  let error: unknown = null;
  for (let i = 0; i < rows.length; i += CHARGE_CHUNK) {
    const chunk = rows.slice(i, i + CHARGE_CHUNK);
    try {
      const r = await post({ invoices: chunk.map((b) => ({ id: b.id, amount: Number(b.balance_due) })) });
      for (const one of r.results) results.set(one.invoice_id, one);
    } catch (e) {
      if (i === 0) throw e;
      for (const row of rows.slice(i)) results.set(row.id, { invoice_id: row.id, outcome: "not_sent", reason: null });
      error = e;
      break;
    }
  }
  return { error, rows: rows.map((row) => ({ row, result: results.get(row.id) ?? { invoice_id: row.id, outcome: "not_found", reason: null } })) };
}

/** The line under the results: what's charging, what was on its way already (not a failure), and what wasn't charged. */
export function chargeSummary(results: Array<Pick<ChargeResult, "outcome">>) {
  const queued = results.filter((r) => r.outcome === "queued").length;
  const onWay = results.filter((r) => r.outcome === "in_progress").length;
  const not = results.length - queued - onWay;
  return [`${queued} charging`, onWay && `${onWay} already on ${onWay === 1 ? "its" : "their"} way`, not && `${not} not charged`].filter(Boolean).join(". ") + ". Each invoice shows when it's paid.";
}

/** What the picked invoices add up to, in cents so a long list doesn't drift. */
export const chargeTotal = (rows: Array<{ balance_due: number }>) => rows.reduce((sum, r) => sum + Math.round(Number(r.balance_due) * 100), 0) / 100;
