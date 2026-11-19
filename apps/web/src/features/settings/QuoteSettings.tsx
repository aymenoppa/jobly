/**
 * Settings → Company → Quotes and payments: the company's switches for its quotes, saved on their
 * own (merge_company_settings), so they never undo a change made elsewhere meanwhile.
 *   settings.payment_schedule.send   a scheduled payment's invoice goes to the client by itself
 *                                    (services/installments.ts), off unless set
 *   settings.quotes.alert_over       "Tell me about quotes over $X": owners, admins and the quote's
 *                                    salesperson hear when one is sent, approved or sent back for
 *                                    changes (20261113001120_high_value_quote_alerts.sql); off empty
 *   settings.quotes.draft_requests   a request from a booking form or the Client Hub gets a draft
 *                                    quote by itself (services/quoteDrafts.ts), off unless set
 *   settings.quote_ai                Draft a quote uses Claude: its own switch, saved at once by the
 *                                    server once Claude answers with the company's key (PUT
 *                                    /quotes/drafting), never with the Save button
 */
import { toUnits } from "@jobly/core/money";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Button, useJustDone } from "@/components/ui/Button";
import { Field, FormError } from "@/components/ui/Field";
import { api, supabase, unwrap } from "@/lib/api";
import { useSession } from "@/lib/session";

interface QuoteForm {
  sendPayments: boolean;
  draftRequests: boolean;
  /** The amount as typed; empty is off. */
  alertOver: string;
}

/** The form's values from the company's settings. */
export function quoteForm(settings: unknown): QuoteForm {
  const s = (settings ?? {}) as Record<string, any>;
  const over = Number(s.quotes?.alert_over);
  return { sendPayments: s.payment_schedule?.send === true, draftRequests: s.quotes?.draft_requests === true, alertOver: typeof s.quotes?.alert_over === "number" && over > 0 ? String(over) : "" };
}

/** The alert amount to save: a number above 0 to the cent, null for off. Throws the field's message when it isn't one. */
export function alertAmount(typed: string): number | null {
  if (!typed.trim()) return null;
  const n = Number(typed);
  if (!(n > 0 && n <= 100_000_000)) throw new Error("Enter an amount above $0 for quote alerts, or leave it empty.");
  // Read as typed, so 2500.555 is $2,500.56 as the database rounds it.
  return Number(toUnits(typed, 2)) / 100;
}

export function QuoteSettings() {
  const session = useSession();
  const { company } = session;
  const queryClient = useQueryClient();
  const details = useQuery({
    queryKey: ["company", company.id],
    queryFn: async () => unwrap(await supabase().from("companies").select("name, slug, phone, email, website, address, timezone, currency, settings, trade_preset").eq("id", company.id).single()),
  });
  const [f, setF] = useState<QuoteForm | null>(null);
  useEffect(() => {
    if (details.data && !f) setF(quoteForm(details.data.settings));
  }, [details.data, f]);
  const save = useMutation({
    meta: { inline: true },
    mutationFn: async (v: QuoteForm) => {
      const settings = { payment_schedule: { send: v.sendPayments }, quotes: { alert_over: alertAmount(v.alertOver), draft_requests: v.draftRequests } };
      unwrap(await supabase().rpc("merge_company_settings", { p_company: company.id, p_settings: settings as never }));
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["company", company.id] });
      session.refresh();
    },
  });
  const saved = useJustDone(save);
  // Claude for drafts: the server checks the key with Claude before it turns on.
  const ai = useMutation({
    meta: { inline: true },
    mutationFn: (on: boolean) => api.put<{ on: boolean }>("/quotes/drafting", { ai: on }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["company", company.id] });
      session.refresh();
    },
  });
  const aiOn = ((details.data?.settings ?? {}) as { quote_ai?: { on?: boolean } }).quote_ai?.on === true;
  if (!f) return null;
  return (
    <form className="card card-pad stack" onSubmit={(e) => { e.preventDefault(); save.mutate(f); }}>
      <strong>Quotes and payments</strong>
      <Field label="Tell me about quotes over" optional hint="When a quote of at least this much is sent, approved, or the client asks for changes, owners, admins and its salesperson hear about it on the bell and their phone, except whoever did it. Empty is off.">
        <span className="input-group" style={{ maxWidth: 180 }}>
          <span className="addon">$</span>
          <input className="input" inputMode="decimal" style={{ paddingLeft: 22 }} value={f.alertOver} placeholder="Off" onChange={(e) => setF({ ...f, alertOver: e.target.value.replace(/[^0-9.]/g, "") })} />
        </span>
      </Field>
      <label className="switch-row" style={{ fontWeight: 400 }}>
        <input type="checkbox" className="switch" checked={ai.isPending ? Boolean(ai.variables) : aiOn} disabled={ai.isPending} onChange={(e) => ai.mutate(e.target.checked)} />
        Draft quotes with AI
      </label>
      <span className="muted small">
        Draft a quote, on a request, has AI read what the client asked for and pick lines from your price list, with quantities when they gave them. It never makes up an item or a price, and nothing is sent: you look it over. Each draft is an ask of your Claude or OpenAI key from the Apps page (or, when someone presses Draft a quote themselves, of their own ChatGPT plan if they connected one). Off, drafts take the price list items whose names match their answers. Saved as you switch it.
      </span>
      <FormError error={ai.error} />
      <label className="switch-row" style={{ fontWeight: 400 }}>
        <input type="checkbox" className="switch" checked={f.draftRequests} onChange={(e) => setF({ ...f, draftRequests: e.target.checked })} />
        Draft a quote when a request comes in
      </label>
      <span className="muted small">For requests from your booking forms and the Client Hub. The person the request is assigned to, or else the office, is told when the draft is ready.</span>
      <label className="switch-row" style={{ fontWeight: 400 }}>
        <input type="checkbox" className="switch" checked={f.sendPayments} onChange={(e) => setF({ ...f, sendPayments: e.target.checked })} />
        Send scheduled payments to clients by themselves
      </label>
      <span className="muted small">
        A quote's payment schedule becomes invoices on its job as each payment comes due. Off, each one waits in Drafts and the people who handle invoices are told. On, it's sent to the client the usual way, and they're told only if it couldn't be sent. A payment due when the work starts waits 30 minutes after the first visit is started, and isn't sent if that visit is put back in that time.
      </span>
      <FormError error={save.error} />
      <div className="form-actions" style={{ justifyContent: "flex-start" }}>
        <Button type="submit" variant="primary" loading={save.isPending} done={saved}>Save</Button>
      </div>
    </form>
  );
}
