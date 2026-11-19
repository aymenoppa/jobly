/**
 * A saved bank account is never charged more than the autopay limit
 * (supabase/migrations/20261116000100_bank_charges_over_the_limit_go_to_the_client.sql). The
 * database refuses the charge wherever one could be made and closes it; this sends its invoice to
 * the client the usual way (sales.ts sendInvoice: the invoice email with its Pay link, or a text to
 * a client with a phone and no email), with one sentence saying why it's theirs to pay. Each is
 * handed over once (claim_autopay_sends), and the database tells the office once how it went
 * (autopay_sent): it went to the client, or it couldn't be sent and is theirs to send, when the
 * invoice stays as it was. Nothing here ever charges anything.
 */
import { AUTOPAY_YOURS_TO_PAY } from "@jobly/core/autopay";
import { isPlaceholderEmail } from "@jobly/core/email";
import type { Env } from "../env";
import { isEmail } from "../lib/email";
import { HttpError } from "../lib/http";
import { reportError } from "../lib/monitoring";
import { adminClient, type Db } from "../lib/supabase";
import { chargeDueAutopay, type AutopayTaskResult } from "./autopay";
import { sendInvoice } from "./sales";

/** As many as one run sends: each is an email or a text. */
const BATCH = 20;
/** An invoice that can still be sent to be paid. */
const TO_PAY = ["draft", "sent", "partially_paid", "overdue"];

/** What one run sent, by how each invoice ended up. */
export type OverLimitSends = { claimed: number; sent: number; failed: number; called_off: number };

/** Send the invoices of charges closed over a bank account's limit, each once. */
export async function sendOverLimitInvoices(env: Env, admin: Db = adminClient(env), options: { companyId?: string } = {}): Promise<OverLimitSends> {
  const { data, error } = await admin.rpc("claim_autopay_sends", { p_limit: BATCH, p_company: options.companyId });
  if (error) throw new Error(`claim_autopay_sends failed: ${error.message}`);
  const claimed = (data ?? []) as Array<{ id: string; company_id: string; invoice_id: string; send_draft: boolean | null }>;
  const counts: OverLimitSends = { claimed: claimed.length, sent: 0, failed: 0, called_off: 0 };
  const baseUrl = (env.APP_URL ?? "").replace(/\/$/, "");
  for (const row of claimed) {
    let sent = false;
    let reason: string | null = null;
    try {
      if (!baseUrl) throw new HttpError(501, "This server has no web address set (APP_URL), so it can't send links to clients");
      const { data: invoice } = await admin.from("invoices").select("status, balance_due, client:clients(email, phone)").eq("company_id", row.company_id).eq("id", row.invoice_id).maybeSingle();
      // Paid, voided or deleted since it was claimed: there's nothing to ask the client for. And a
      // draft when its charge was closed that isn't one now was sent by the office in the moment
      // since: it isn't sent a second time.
      if (!invoice || !TO_PAY.includes(invoice.status) || Number(invoice.balance_due) <= 0 || (row.send_draft && invoice.status !== "draft")) {
        const { error: offError } = await admin.rpc("autopay_send_called_off", { p_charge: row.id });
        if (offError) reportError(new Error(offError.message), { task: "autopay", step: "autopay_send_called_off" });
        counts.called_off++;
        continue;
      }
      // By email, or by text to a client with a phone and no email: what the Send dialog starts with.
      const client = invoice.client as { email: string | null; phone: string | null } | null;
      const channel = !(isEmail(client?.email) && !isPlaceholderEmail(client?.email)) && client?.phone ? "sms" : "email";
      const result = await sendInvoice({ db: admin, env, companyId: row.company_id, baseUrl }, row.invoice_id, { channel }, { note: AUTOPAY_YOURS_TO_PAY });
      sent = result.sent;
      reason = result.sent ? null : (result.reason ?? "It wasn't sent");
    } catch (err) {
      reason = err instanceof HttpError ? err.message : "It couldn't be sent";
      if (!(err instanceof HttpError)) reportError(err, { task: "autopay", invoice: row.invoice_id });
    }
    const { error: settleError } = await admin.rpc("autopay_sent", { p_charge: row.id, p_sent: sent, ...(reason ? { p_error: reason } : {}) });
    if (settleError) reportError(new Error(settleError.message), { task: "autopay", step: "autopay_sent" });
    if (sent) counts.sent++;
    else counts.failed++;
  }
  return counts;
}

/**
 * The 5-minute autopay task, and what follows the office's OK or its Charge card: charge what's due
 * (services/autopay.ts), then send the invoices the database closed instead of charging, so one
 * closed in this run goes out in it. A problem sending never undoes a charge, and a run that
 * couldn't charge (the claim failed) still sends what was waiting before it fails as it would have.
 */
export async function runAutopay(env: Env, admin: Db = adminClient(env), options: { limit?: number; companyId?: string } = {}): Promise<AutopayTaskResult & { to_client: OverLimitSends }> {
  const send = async (): Promise<OverLimitSends> => {
    try {
      return await sendOverLimitInvoices(env, admin, { companyId: options.companyId });
    } catch (thrown) {
      console.error("Couldn't send the invoices over a bank account's limit", thrown);
      reportError(thrown, { task: "autopay", step: "send_over_limit" });
      return { claimed: 0, sent: 0, failed: 0, called_off: 0 };
    }
  };
  let charged: AutopayTaskResult;
  try {
    charged = await chargeDueAutopay(env, admin, options);
  } catch (thrown) {
    await send();
    throw thrown;
  }
  return { ...charged, to_client: await send() };
}
