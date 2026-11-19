/**
 * A quote's payment schedule on its job (20261113001100_payment_schedules.sql). The database makes
 * each payment's invoice when its moment comes (a date, the work starting) as a draft. When the
 * company has "Send scheduled payments to clients by themselves" on (settings.payment_schedule.send),
 * this sends them the usual way (sales.ts sendInvoice): every five minutes, each once. One that
 * doesn't go stays in Drafts and the office is told why (installment_sent).
 *
 * The database only hands over drafts, and one made because a visit was started only half an hour
 * after (20261113001620_started_payments_wait_before_sending.sql). An invoice the office sent by
 * hand in the moment since is never sent again: the send is called off instead.
 */
import type { Env } from "../env";
import { HttpError } from "../lib/http";
import { reportError } from "../lib/monitoring";
import { adminClient } from "../lib/supabase";
import { sendInvoice } from "./sales";

/** As many as one run sends: each is an email or a text. */
const BATCH = 20;

export async function sendScheduledPayments(env: Env) {
  const admin = adminClient(env);
  const { data, error } = await admin.rpc("claim_installment_sends", { p_limit: BATCH });
  if (error) throw new Error(error.message);
  const claimed = (data ?? []) as Array<{ id: string; company_id: string; invoice_id: string }>;
  const counts = { claimed: claimed.length, sent: 0, failed: 0, called_off: 0 };
  const baseUrl = (env.APP_URL ?? "").replace(/\/$/, "");
  for (const row of claimed) {
    let sent = false;
    let reason: string | null = null;
    try {
      if (!baseUrl) throw new HttpError(501, "This server has no web address set (APP_URL), so it can't send links to clients");
      // By email, or by text to a client with a phone and no email: what the Send dialog starts with.
      const { data: invoice } = await admin.from("invoices").select("status, client:clients(email, phone)").eq("id", row.invoice_id).maybeSingle();
      // Sent by hand, voided or deleted since it was claimed: sendInvoice would send it again.
      if (invoice?.status !== "draft") {
        const { error: offError } = await admin.rpc("installment_send_called_off", { p_installment: row.id });
        if (offError) reportError(new Error(offError.message), { task: "installments", step: "installment_send_called_off" });
        counts.called_off++;
        continue;
      }
      const client = invoice?.client as { email: string | null; phone: string | null } | null | undefined;
      const channel = !client?.email && client?.phone ? "sms" : "email";
      const result = await sendInvoice({ db: admin, env, companyId: row.company_id, baseUrl }, row.invoice_id, { channel });
      sent = result.sent;
      reason = result.sent ? null : (result.reason ?? "It wasn't sent");
    } catch (err) {
      reason = err instanceof HttpError ? err.message : "It couldn't be sent";
      if (!(err instanceof HttpError)) reportError(err, { task: "installments", invoice: row.invoice_id });
    }
    const { error: settleError } = await admin.rpc("installment_sent", { p_installment: row.id, p_sent: sent, ...(reason ? { p_error: reason } : {}) });
    if (settleError) reportError(new Error(settleError.message), { task: "installments", step: "installment_sent" });
    if (sent) counts.sent++;
    else counts.failed++;
  }
  return counts;
}
