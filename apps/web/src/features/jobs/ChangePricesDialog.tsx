/**
 * Change prices across repeating jobs, from the Jobs page (core priceChange; the database's rules
 * are in 20261113000950_price_changes.sql). Pick the jobs (all active repeating ones, the ones
 * ticked on the list, or narrowed by a service on the job, a client tag or a crew) and the change (a
 * percentage or an amount on each line's price, up or down, on all lines or one service's,
 * rounded). Preview shows every job and line before anything changes, and can be downloaded. Apply
 * sends the jobs a group at a time; the database makes each group's change only if it's exactly
 * what was previewed, so no job is half changed. Earlier changes are listed with Undo.
 */
import {
  autopayNote, PRICE_CHANGE_COLUMNS, priceChangeGroups, priceChangeOf, priceChangeRows, priceChangeTotals, priceIsFor, ROUNDING_CHOICES,
  type PriceChange, type PriceChangeKind, type PriceChangePreview, type PriceRounding,
} from "@jobly/core/priceChange";
import type { Json } from "@jobly/core/database";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { Select } from "@/components/ui/Select";
import { supabase, unwrap } from "@/lib/api";
import { downloadCsv, toCsv } from "@/lib/csv";
import { errorMessage } from "@/lib/errors";
import { formatDateTime, formatMoney, formatMoneyCents, todayIn } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { useClientTags } from "../clients/ClientForm";
import { useCrews } from "./JobDialogs";

interface HistoryRow { id: string; summary: string; jobs: number; lines: number; created_at: string; by: string | null; undone_at: string | null; invoice: number | null }

const plural = (n: number, one: string) => `${n} ${n === 1 ? one : `${one}s`}`;

/** What Apply reports when a later group of jobs is turned down: the earlier groups are changed and stay so. */
export const partlyApplied = (done: number, total: number, reason: string) => `Prices changed on ${done} of ${total} jobs. The rest weren't changed: ${reason}`;

export function ChangePricesDialog({ picked, onClose, onChanged }: { picked: readonly string[]; onClose: () => void; onChanged: () => void }) {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const crews = useCrews();
  const tags = useClientTags();
  const services = useQuery({
    queryKey: ["services", company.id, "names"],
    staleTime: 5 * 60_000,
    queryFn: async () => unwrap(await supabase().from("services").select("id, name").eq("company_id", company.id).eq("active", true).order("name")),
  });
  const history = useQuery({
    queryKey: ["price-changes", company.id],
    queryFn: async () => (unwrap(await supabase().rpc("price_change_history", { p_company: company.id })) ?? []) as unknown as HistoryRow[],
  });

  const [scope, setScope] = useState<"all" | "picked">(picked.length ? "picked" : "all");
  const [serviceId, setServiceId] = useState("");
  const [tag, setTag] = useState("");
  const [crewId, setCrewId] = useState("");
  const [direction, setDirection] = useState<"up" | "down">("up");
  const [kind, setKind] = useState<PriceChangeKind>("percent");
  const [amount, setAmount] = useState("");
  const [round, setRound] = useState<PriceRounding>("cent");
  const [lineServiceId, setLineServiceId] = useState("");
  const [problem, setProblem] = useState<string | null>(null);
  // The preview on screen and the change it's of: any edit to the form above takes it away.
  const [shown, setShown] = useState<{ change: PriceChange; preview: PriceChangePreview } | null>(null);
  // The jobs unticked in the preview.
  const [left, setLeft] = useState<ReadonlySet<string>>(new Set());
  const [done, setDone] = useState<{ jobs: number } | null>(null);
  const edit = <T,>(set: (value: T) => void) => (value: T) => {
    set(value);
    setShown(null);
    setProblem(null);
  };

  const preview = useMutation({
    meta: { inline: true },
    mutationFn: async (change: PriceChange) => ({ change, preview: unwrap(await supabase().rpc("price_change_preview", { p_company: company.id, p_change: change as unknown as Json })) as unknown as PriceChangePreview }),
    onSuccess: (result) => {
      setShown(result);
      setLeft(new Set());
    },
  });
  const ask = (e: FormEvent) => {
    e.preventDefault();
    const change = priceChangeOf({
      direction, kind, amount, round, lineServiceId: lineServiceId || null,
      pick: { service_id: serviceId || null, client_tag: tag || null, crew_id: crewId || null, job_ids: scope === "picked" ? [...picked] : null },
    });
    if (typeof change === "string") return setProblem(change);
    setProblem(null);
    preview.mutate(change);
  };

  const only = shown ? new Set(shown.preview.jobs.filter((j) => !left.has(j.job_id)).map((j) => j.job_id)) : new Set<string>();
  const totals = shown ? priceChangeTotals(shown.preview.jobs, only) : null;
  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: ["jobs", company.id] });
    void queryClient.invalidateQueries({ queryKey: ["job"] });
    void queryClient.invalidateQueries({ queryKey: ["price-changes", company.id] });
    onChanged();
  };
  const apply = useMutation({
    meta: { inline: true },
    mutationFn: async () => {
      const groups = priceChangeGroups(shown!.preview.jobs, only);
      const total = groups.reduce((n, g) => n + g.jobs, 0);
      // One id for the whole change, so its groups are one change to undo.
      const id = crypto.randomUUID();
      let changed = 0;
      for (const group of groups) {
        try {
          unwrap(await supabase().rpc("apply_price_change", { p_company: company.id, p_id: id, p_change: shown!.change as unknown as Json, p_lines: group.lines as unknown as Json }));
        } catch (error) {
          if (!changed) throw error;
          refresh();
          throw new Error(partlyApplied(changed, total, errorMessage(error)));
        }
        changed += group.jobs;
      }
      return { jobs: changed };
    },
    onSuccess: (result) => {
      toast.success(`Prices changed on ${plural(result.jobs, "job")}`, { tone: "job" });
      setDone(result);
      setShown(null);
      refresh();
    },
  });
  const undo = useMutation({
    meta: { inline: true },
    mutationFn: async (change: HistoryRow) => {
      const ok = await confirm({ title: "Undo this price change?", body: `${change.summary}, on ${plural(change.jobs, "job")}. Every line it changed goes back to its old price. A line someone has changed since is left as it is.`, confirmLabel: "Undo the change" });
      if (!ok) return null;
      return unwrap(await supabase().rpc("undo_price_change", { p_company: company.id, p_id: change.id })) as unknown as { restored: number; left: number };
    },
    onSuccess: (result) => {
      if (!result) return;
      toast.success(`Old prices are back on ${plural(result.restored, "line")}`, { tone: "job", ...(result.left > 0 && { description: `${plural(result.left, "line")} changed since ${result.left === 1 ? "was" : "were"} left as ${result.left === 1 ? "it is" : "they are"}.` }) });
      refresh();
    },
  });
  const download = () => {
    if (!shown) return;
    downloadCsv(`price-change-${todayIn(company.timezone)}.csv`, toCsv(priceChangeRows(shown.preview.jobs, only), [...PRICE_CHANGE_COLUMNS]));
  };
  const note = totals && shown?.preview.autopay ? autopayNote(totals, shown.preview.autopay.limit, (n) => (Number.isInteger(n) ? formatMoney(n) : formatMoneyCents(n))) : null;

  return (
    <Dialog open onClose={onClose} title="Change prices" description="Raise or lower the prices on your repeating jobs. You'll see every job and line before anything changes." size="xl">
      <form onSubmit={ask} className="stack">
        {done && (
          <div className="callout callout-info" role="status">
            <Icon name="check" size={20} />
            <div className="grow">Prices changed on {plural(done.jobs, "job")}. Invoices made from now on use them. You can undo the change below until one of those jobs is invoiced.</div>
          </div>
        )}
        <section className="stack-sm">
          <strong>Which jobs</strong>
          {picked.length > 0 && (
            <div className="segmented" role="group" aria-label="Which jobs">
              <button type="button" aria-pressed={scope === "picked"} onClick={() => edit(setScope)("picked")}>The {plural(picked.length, "job")} ticked on the list</button>
              <button type="button" aria-pressed={scope === "all"} onClick={() => edit(setScope)("all")}>All active repeating jobs</button>
            </div>
          )}
          <div className="row wrap" style={{ gap: 12, alignItems: "flex-end" }}>
            <Field label="With this service" optional>
              <Select className="select" value={serviceId} onChange={(e) => edit(setServiceId)(e.target.value)}>
                <option value="">Any service</option>
                {services.data?.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
              </Select>
            </Field>
            <Field label="Client tag" optional>
              <Select className="select" value={tag} onChange={(e) => edit(setTag)(e.target.value)}>
                <option value="">Any tag</option>
                {tags.data?.map((t) => <option key={t} value={t}>{t}</option>)}
              </Select>
            </Field>
            <Field label="Crew" optional>
              <Select className="select" value={crewId} onChange={(e) => edit(setCrewId)(e.target.value)}>
                <option value="">Any crew</option>
                {crews.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
              </Select>
            </Field>
          </div>
          <span className="muted small">Only active repeating jobs are changed{scope === "picked" ? ", so a one-off job you ticked is passed over" : ""}. One-off jobs keep their prices.</span>
        </section>

        <section className="stack-sm">
          <strong>The change</strong>
          <div className="row wrap" style={{ gap: 12, alignItems: "flex-end" }}>
            <div className="segmented" role="group" aria-label="Raise or lower">
              <button type="button" aria-pressed={direction === "up"} onClick={() => edit(setDirection)("up")}>Raise</button>
              <button type="button" aria-pressed={direction === "down"} onClick={() => edit(setDirection)("down")}>Lower</button>
            </div>
            <div className="segmented" role="group" aria-label="By a percentage or an amount">
              <button type="button" aria-pressed={kind === "percent"} onClick={() => edit(setKind)("percent")}>By a percentage</button>
              <button type="button" aria-pressed={kind === "amount"} onClick={() => edit(setKind)("amount")}>By an amount on each line</button>
            </div>
            <span className="input-group" style={{ width: 130 }}>
              <span className={kind === "percent" ? "addon addon-right" : "addon"}>{kind === "percent" ? "%" : "$"}</span>
              <input className="input" style={kind === "amount" ? { paddingLeft: 22 } : undefined} inputMode="decimal" autoFocus aria-label={kind === "percent" ? "Percent" : "Amount added to or taken off each line's price"} value={amount} onChange={(e) => edit(setAmount)(e.target.value.replace(/[^0-9.]/g, ""))} />
            </span>
          </div>
          <div className="row wrap" style={{ gap: 12, alignItems: "flex-end" }}>
            <Field label="Lines">
              <Select className="select" value={lineServiceId} onChange={(e) => edit(setLineServiceId)(e.target.value)}>
                <option value="">All lines</option>
                {services.data?.map((s) => <option key={s.id} value={s.id}>Only {s.name} lines</option>)}
              </Select>
            </Field>
            <Field label="Round new prices">
              <Select className="select" value={round} onChange={(e) => edit(setRound)(e.target.value as PriceRounding)}>
                {ROUNDING_CHOICES.map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
              </Select>
            </Field>
          </div>
          <span className="muted small">
            Invoices made from now on use the new prices. Nothing already invoiced changes, and nothing is sent to clients. Lines at $0, discounts and one-time extra work on a visit aren't changed.
          </span>
        </section>

        <FormError error={problem ?? preview.error} />
        {!shown && (
          <div className="form-actions">
            <Button onClick={onClose}>{done ? "Done" : "Cancel"}</Button>
            <Button type="submit" variant="primary" icon="eye" loading={preview.isPending}>Preview</Button>
          </div>
        )}

        {shown && totals && (
          <section className="stack-sm" aria-label="Preview">
            <div className="row-between wrap" style={{ gap: 8 }}>
              <strong>{shown.preview.summary}</strong>
              {shown.preview.jobs.length > 0 && <Button size="sm" icon="download" onClick={download}>Download CSV</Button>}
            </div>
            {shown.preview.jobs.length === 0 ? (
              <p className="muted" style={{ margin: 0 }}>No job would change. Try other jobs, or a larger change.</p>
            ) : (
              <>
                <div className="card" style={{ boxShadow: "none", maxHeight: 360, overflowY: "auto" }}>
                  <table className="table">
                    <thead><tr><th style={{ width: 36 }}><span className="sr-only">Change this job</span></th><th>Client and job</th><th>Lines</th><th className="num">Job's price</th></tr></thead>
                    <tbody>
                      {shown.preview.jobs.map((j) => (
                        <tr key={j.job_id} style={left.has(j.job_id) ? { opacity: 0.5 } : undefined}>
                          <td>
                            <input type="checkbox" checked={!left.has(j.job_id)} aria-label={`Change job #${j.number}`} onChange={(e) => { const next = new Set(left); e.target.checked ? next.delete(j.job_id) : next.add(j.job_id); setLeft(next); }} />
                          </td>
                          <td>
                            <strong>{j.client}</strong>
                            <div className="muted small"><Link to={`/jobs/${j.job_id}`} target="_blank" rel="noreferrer">#{j.number}</Link> · {j.title}</div>
                            {j.autopay && <span className={`chip ${j.over_limit && !j.was_over_limit ? "chip-amber" : ""}`}><Icon name="card" size={12} />{j.over_limit ? "Autopay, over your limit" : "Autopay"}</span>}
                          </td>
                          <td>
                            {j.lines.map((l) => (
                              <div key={l.line_id} className="small">
                                {l.name}{Number(l.quantity) !== 1 ? ` × ${Number(l.quantity)}` : ""}: <span className="muted tabular">{formatMoneyCents(Number(l.old_price))}</span> → <strong className="tabular">{formatMoneyCents(Number(l.new_price))}</strong>
                              </div>
                            ))}
                          </td>
                          <td className="num">
                            <span className="muted tabular">{formatMoneyCents(Number(j.old_price))}</span> → <strong className="tabular">{formatMoneyCents(Number(j.new_price))}</strong>
                            <div className="muted small">{priceIsFor(j)}</div>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <div className="row-between wrap" style={{ gap: 8 }}>
                  <span>{plural(totals.jobs, "job")}, {plural(totals.lines, "line")}</span>
                  <span>Together <span className="muted tabular">{formatMoneyCents(totals.old_price)}</span> → <strong className="tabular">{formatMoneyCents(totals.new_price)}</strong> <span className="muted small">(a visit or a month of each)</span></span>
                </div>
                {note && <div className="callout callout-info"><Icon name="card" size={20} /><div className="grow">{note}</div></div>}
              </>
            )}
            <FormError error={apply.error} />
            <div className="form-actions">
              <Button onClick={onClose}>Cancel</Button>
              <Button variant="primary" icon="check" loading={apply.isPending} disabled={!totals.jobs} onClick={() => apply.mutate()}>
                {totals.jobs ? `Change prices on ${plural(totals.jobs, "job")}` : "Change prices"}
              </Button>
            </div>
          </section>
        )}

        {history.data && history.data.length > 0 && (
          <section className="stack-sm" aria-label="Earlier changes">
            <strong>Earlier changes</strong>
            <div className="card" style={{ boxShadow: "none" }}>
              {history.data.map((h) => (
                <div key={h.id} className="card-row" style={{ padding: "10px 14px" }}>
                  <span className="grow" style={{ minWidth: 0 }}>
                    <strong>{h.summary}</strong>
                    <span className="muted small" style={{ display: "block" }}>
                      {plural(h.jobs, "job")}, {plural(h.lines, "line")} · {formatDateTime(h.created_at, company.timezone)}{h.by ? ` · ${h.by}` : ""}
                      {h.undone_at ? " · undone" : h.invoice ? ` · can't be undone: invoice #${h.invoice} was made at the new prices` : ""}
                    </span>
                  </span>
                  {!h.undone_at && !h.invoice && <Button size="sm" icon="undo" loading={undo.isPending && undo.variables?.id === h.id} onClick={() => undo.mutate(h)}>Undo</Button>}
                </div>
              ))}
            </div>
            <FormError error={undo.error} />
          </section>
        )}
      </form>
    </Dialog>
  );
}
