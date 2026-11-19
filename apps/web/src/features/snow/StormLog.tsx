/**
 * Snow → Season: every storm this season at every snow customer (snow_events, written when its
 * people are told or it's scheduled): what was forecast, what fell (the forecast's own estimate the
 * day after, until the office writes what it measured), the storm's visits with a report for each
 * (SnowReportPage.tsx), and what it bills. A customer with storm prices bills by the depth that
 * fell (private.snow_price, which follows this figure until the visit is invoiced); one without
 * bills each push the job's own lines. Above it, the season so far, by customer.
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { NumberInput } from "@/components/ui/NumberInput";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { StatusPill } from "@/components/ui/StatusPill";
import { supabase, unwrap } from "@/lib/api";
import { addressLine, formatDate, formatMoney, todayIn } from "@/lib/format";
import { useSession } from "@/lib/session";
import { inches } from "./snowData";

const FIELDS =
  "job_id, snow_date, kind, forecast_in, actual_in, actual_by, pushes, job:jobs!inner(number, title, client:clients(display_name), property:properties(line1, city), financials:job_financials(contract_total)), visits:snow_visits(visit:visits(id, title, status, price, invoice_id))";
const loadEvents = async (companyId: string, since: string) =>
  unwrap(await supabase().from("snow_events").select(FIELDS).eq("company_id", companyId).gte("snow_date", since).order("snow_date", { ascending: false }).limit(1000));
type Storm = Awaited<ReturnType<typeof loadEvents>>[number];

/** A snow season runs July to June: the winter is one season, whichever year a storm falls in. */
const seasonStart = (today: string) => `${Number(today.slice(0, 4)) - (Number(today.slice(5, 7)) >= 7 ? 0 : 1)}-07-01`;
const name = (e: Storm) => e.job.client?.display_name ?? e.job.title;
const depth = (e: Storm) => (e.actual_in ?? e.forecast_in) as number | null;
const visitsOf = (e: Storm) => e.visits.flatMap((v) => (v.visit && v.visit.status !== "cancelled" ? [v.visit] : []));
/** What a visit bills: its own price (a storm priced by depth), or the job's lines. */
function charge(e: Storm, visit: { price: number | null }): number {
  const lines = Array.isArray(e.job.financials) ? e.job.financials[0] : e.job.financials;
  return Number(visit.price ?? lines?.contract_total ?? 0);
}
const done = (e: Storm) => visitsOf(e).filter((v) => v.status === "completed");
const billed = (e: Storm) => done(e).reduce((total, v) => total + charge(e, v), 0);

export function StormLog() {
  const { company } = useSession();
  const since = seasonStart(todayIn(company.timezone));
  const storms = useQuery({ queryKey: ["snow", company.id, "log", since], queryFn: () => loadEvents(company.id, since) });
  if (storms.isPending) return <div className="card card-pad"><Skeleton width="50%" /><Skeleton width="80%" /><Skeleton width="65%" /></div>;
  if (storms.error && !storms.data) return <div className="card"><ErrorState error={storms.error} onRetry={() => storms.refetch()} /></div>;
  const all = storms.data ?? [];
  if (!all.length) {
    return (
      <div className="card">
        <EmptyState icon="snow" title="No storms logged this season">
          A storm goes in the log when a snow customer's people are told about it, or when you schedule it. What fell is filled in the day after.
        </EmptyState>
      </div>
    );
  }
  const customers = [...new Map(all.map((e) => [e.job_id, e])).values()]
    .map((first) => {
      const mine = all.filter((e) => e.job_id === first.job_id);
      return { first, storms: mine.length, snow: mine.reduce((n, e) => n + (depth(e) ?? 0), 0), visits: mine.reduce((n, e) => n + done(e).length, 0), billed: mine.reduce((n, e) => n + billed(e), 0) };
    })
    .sort((a, b) => name(a.first).localeCompare(name(b.first)));
  return (
    <>
      <div className="stat-row">
        <div className="card stat"><div className="label">Storm days this season</div><div className="value">{new Set(all.map((e) => e.snow_date)).size}</div><div className="hint">Since {formatDate(since)}</div></div>
        <div className="card stat"><div className="label">Customers with a storm</div><div className="value">{customers.length}</div><div className="hint">{all.length} {all.length === 1 ? "storm" : "storms"} between them</div></div>
        <div className="card stat"><div className="label">Visits done</div><div className="value">{customers.reduce((n, c) => n + c.visits, 0)}</div><div className="hint">Plow and salt</div></div>
        <div className="card stat"><div className="label">Billed for them</div><div className="value">{formatMoney(customers.reduce((n, c) => n + c.billed, 0))}</div><div className="hint">Before tax, for the visits done</div></div>
      </div>
      <div className="card">
        <div className="card-head"><h2>This season by customer</h2></div>
        <table className="table table-stack">
          <thead><tr><th>Customer</th><th>Storms</th><th>Snow</th><th>Visits done</th><th>Billed</th></tr></thead>
          <tbody>
            {customers.map((c) => (
              <tr key={c.first.job_id}>
                <td><Link className="cell-link" to={`/jobs/${c.first.job_id}`}>{name(c.first)}</Link><div className="muted small">{addressLine(c.first.job.property) || c.first.job.title}</div></td>
                <td className="tabular">{c.storms} <span className="muted small">{c.storms === 1 ? "storm" : "storms"}</span></td>
                <td className="tabular">{inches(c.snow)} <span className="muted small">total</span></td>
                <td className="tabular">{c.visits} <span className="muted small">{c.visits === 1 ? "visit" : "visits"}</span></td>
                <td className="tabular">{formatMoney(c.billed)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <div className="card">
        <div className="card-head"><h2>Storms</h2><span className="muted small">What fell sets a storm's price, until its visit is invoiced</span></div>
        <table className="table table-stack">
          <thead><tr><th>Storm</th><th>Customer</th><th>Snow</th><th>Visits</th><th>Bills</th></tr></thead>
          <tbody>{all.map((e) => <StormRow key={`${e.job_id}:${e.snow_date}`} storm={e} />)}</tbody>
        </table>
        <div className="list-foot"><span>{all.length} {all.length === 1 ? "storm" : "storms"}</span></div>
      </div>
    </>
  );
}

function StormRow({ storm: e }: { storm: Storm }) {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const [fell, setFell] = useState(e.actual_in == null ? "" : String(e.actual_in));
  const save = useMutation({
    meta: { success: "What fell is saved" },
    mutationFn: async () => {
      const amount = fell.trim() === "" ? null : Number(fell);
      if (amount != null && !(amount >= 0 && amount <= 100)) throw new Error("What fell is 0 to 100 inches.");
      unwrap(await supabase().from("snow_events").update({ actual_in: amount }).eq("job_id", e.job_id).eq("snow_date", e.snow_date));
    },
    onSettled: () => queryClient.invalidateQueries({ queryKey: ["snow", company.id, "log"] }),
  });
  const changed = fell.trim() !== (e.actual_in == null ? "" : String(e.actual_in));
  const visits = visitsOf(e);
  const finished = done(e);
  return (
    <tr>
      <td>
        <span className="strong">{formatDate(e.snow_date)}</span>
        <div className="muted small">{e.kind === "salt" ? "Salt run" : e.pushes > 1 ? `Plow, ${e.pushes} pushes` : "Plow"}</div>
      </td>
      <td><Link className="cell-link" to={`/jobs/${e.job_id}`}>{name(e)}</Link><div className="muted small">{addressLine(e.job.property) || e.job.title}</div></td>
      <td>
        <span className="row" style={{ gap: 6 }}>
          <span className="input-group" style={{ width: 104 }}>
            <NumberInput
              className="input" inputMode="decimal" min={0} max={100} step={0.1} value={fell} placeholder="—" aria-label={`What fell at ${name(e)} on ${formatDate(e.snow_date)}, in inches`}
              onChange={(ev) => setFell(ev.target.value)} onBlur={() => changed && save.mutate()} onKeyDown={(ev) => ev.key === "Enter" && changed && save.mutate()}
            />
            <span className="addon addon-right addon-unit">in</span>
          </span>
          <span className="muted small">fell</span>
        </span>
        <div className="muted small">
          {e.actual_in == null ? "Not known yet" : e.actual_by ? "As the office wrote it" : "The forecast's estimate"}{e.forecast_in != null ? ` · ${inches(Number(e.forecast_in))} was forecast` : ""}
        </div>
        {save.error && <div className="small text-danger">{save.error.message}</div>}
      </td>
      <td>
        {visits.length ? `${finished.length} of ${visits.length} done` : <span className="muted">Not scheduled</span>}
        {visits.map((v, i) => (
          <div key={v.id} className="small"><Link to={`/snow/report/${v.id}`}>{visits.length > 1 ? `Report ${i + 1}` : "Service report"}</Link>{v.status !== "completed" && <span className="muted"> · not done yet</span>}</div>
        ))}
      </td>
      <td>
        <span className="tabular">{finished.length ? formatMoney(billed(e)) : <span className="muted">—</span>}</span>
        {finished.length > 0 && <div style={{ marginTop: 4 }}>{finished.every((v) => v.invoice_id) ? <StatusPill label="Invoiced" tone="good" /> : <StatusPill label="To invoice" tone="warning" />}</div>}
        {/* The estimate runs low where snow is light and dry, and it sets the price: said before the invoice, not after. */}
        {e.actual_by == null && finished.some((v) => v.price != null && !v.invoice_id) && <div className="small" style={{ color: "var(--warning)" }}>Priced on an estimate of what fell. Enter what you measured first.</div>}
      </td>
    </tr>
  );
}
