/**
 * Snow (Apps → Jobly - Snow), in three tabs by what you came to do. Storm: the snow coming from
 * 6pm today through tomorrow (an overnight storm counts whole), a storm that's here today, and
 * what's left to do about each (StormBoard.tsx). Customers: the snow customers themselves, each a
 * job with the snow that sends the plow or the salt out, how it's served, who works it and what a
 * storm bills. A customer's row, on either, opens it in a popup: its address, notes, photos and files
 * (SnowSiteDetails.tsx), with Edit for how it's served. Season: every storm, what fell, its visits and what it bills (StormLog.tsx).
 *
 * The day before, the snow task tells each customer's people what's coming, and on the day about a
 * storm they weren't told of (snowWatch in apps/api/src/tasks.ts); sending them out is the office's
 * call, from the Storm tab (POST /api/snow/schedule puts them on tomorrow's visits, or today's),
 * unless it turned on the switch there that schedules each storm as its people are told. Someone told whose forecast has since dropped
 * says so there, and nobody is sent an all-clear: calling it off is the office's call too.
 */
import { clockText } from "@jobly/core/snow";
import { useQuery } from "@tanstack/react-query";
import { useDeferredValue, useState } from "react";
import { Link, useSearchParams } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Icon } from "@/components/ui/Icon";
import { PageHeader } from "@/components/ui/PageHeader";
import { ListPageSkeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { StatusPill } from "@/components/ui/StatusPill";
import { api } from "@/lib/api";
import { addressLine } from "@/lib/format";
import { useSession } from "@/lib/session";
import { bandsKey, customer, inches, loadBands, loadSites, located, nameOf, sitesKey, tiersOf, type Member, type Site } from "./snowData";
import { StandardPricesDialog } from "./SnowPrices";
import { SnowSiteDetails } from "./SnowSiteDetails";
import { SnowSiteDialog } from "./SnowSiteDialog";
import { SHOP, WeatherDialog, hasShop } from "./SnowWeather";
import { StormBoard } from "./StormBoard";
import { StormLog } from "./StormLog";

const TABS = [{ id: "storm", label: "Storm" }, { id: "customers", label: "Customers" }, { id: "log", label: "Season" }] as const;
type Tab = (typeof TABS)[number]["id"];

export function SnowPage() {
  const { company } = useSession();
  const [params, setParams] = useSearchParams();
  const tab: Tab = TABS.find((t) => t.id === params.get("tab"))?.id ?? "storm";
  const at = (to: Tab): Record<string, string> => (to === "storm" ? {} : { tab: to });
  /** The address bar says which tab, and which popup is open over it. */
  const show = (open: Record<string, string> = {}) => setParams({ ...at(tab), ...open }, { replace: true });
  const editing = params.get("edit") ?? (params.get("new") === "1" ? "new" : null);
  const weatherAt = params.get("weather");
  const opened = params.get("open");
  const sites = useQuery({ queryKey: sitesKey(company.id), queryFn: () => loadSites(company.id) });
  const team = useQuery({ queryKey: ["team", company.id, "with-subs"], staleTime: 5 * 60_000, queryFn: () => api.get<Member[]>("/team?with_subs=1") });
  const bands = useQuery({ queryKey: bandsKey(company.id), queryFn: () => loadBands(company.id) });

  if (sites.isPending) return <ListPageSkeleton columns={4} tabs={3} />;
  const all = sites.data ?? [];
  const site = editing && editing !== "new" ? all.find((s) => s.job_id === editing) : null;
  const openSite = opened ? all.find((s) => s.job_id === opened) : null;
  return (
    <>
      <PageHeader
        title="Snow"
        actions={
          <>
            {/* The shop's weather, with a customer's a pick away; with no shop on the map, a customer's. */}
            {(hasShop(company) || all.some(located)) && <Button icon="cloudSnow" onClick={() => show({ weather: hasShop(company) ? SHOP : all.find(located)!.job_id })}>Weather</Button>}
            {tab === "customers" && <Button icon="dollar" disabled={!bands.data} onClick={() => show({ prices: "1" })}>Standard storm prices</Button>}
            {/* The page's one green button, except on Storm with a storm to schedule: there that's the thing to do. */}
            <Button variant={tab === "storm" && all.length > 0 ? "secondary" : "primary"} icon="plus" onClick={() => show({ new: "1" })}>Add snow customer</Button>
          </>
        }
      />
      <div className="underline-tabs" role="tablist" aria-label="Snow">
        {TABS.map((t) => <button key={t.id} type="button" role="tab" aria-selected={tab === t.id} onClick={() => setParams(at(t.id), { replace: true })}>{t.label}</button>)}
      </div>
      {sites.error && !sites.data ? (
        <div className="card"><ErrorState error={sites.error} onRetry={() => sites.refetch()} /></div>
      ) : tab === "log" ? (
        <StormLog />
      ) : tab === "customers" ? (
        <Customers sites={all} team={team.data ?? []} onOpen={(jobId) => show({ open: jobId })} />
      ) : (
        <StormBoard sites={all} team={team.data ?? []} onOpen={(jobId) => show({ open: jobId })} onWeather={(place) => show({ weather: place })} />
      )}
      {/* Edit, from a customer's popup, goes back to it. */}
      {openSite && !editing && !weatherAt && (
        <SnowSiteDetails key={openSite.job_id} site={openSite} team={team.data ?? []} onEdit={() => show({ open: openSite.job_id, edit: openSite.job_id })} onWeather={() => show({ weather: openSite.job_id })} onClose={() => show()} />
      )}
      {editing && (editing === "new" || site) && (
        <SnowSiteDialog key={editing} site={site ?? null} team={(team.data ?? []).filter((m) => m.active || site?.people.some((p) => p.user_id === m.user_id))} onClose={() => show(openSite ? { open: openSite.job_id } : {})} />
      )}
      {params.get("prices") === "1" && bands.data && <StandardPricesDialog saved={bands.data} onClose={() => show()} />}
      {weatherAt && <WeatherDialog sites={all} place={weatherAt} onPick={(place) => show({ weather: place })} onClose={() => show()} />}
    </>
  );
}

/** The snow customers as they're set up: what sends the plow and the salt, how each is served, who works it and what a storm bills. */
function Customers({ sites: all, team, onOpen }: { sites: Site[]; team: Member[]; onOpen: (jobId: string) => void }) {
  const [search, setSearch] = useState("");
  const term = useDeferredValue(search.trim().toLowerCase());
  const members = new Map(team.map((m) => [m.user_id, m]));
  const unlocated = all.filter((s) => !s.job.paused_at && !located(s));
  const rows = all
    .filter((s) => !term || [customer(s), s.job.title, addressLine(s.job.property), s.job.crew?.name].some((v) => v?.toLowerCase().includes(term)))
    .sort((a, b) => customer(a).localeCompare(customer(b)));
  if (all.length === 0) {
    return (
      <div className="card">
        {/* Add snow customer is the page header's green button, so it isn't repeated here. */}
        <EmptyState icon="snow" title="No snow customers yet">
          Add a job as a snow customer with the inches of snow that call for it. The day before, its crew and anyone else on it are told when the forecast from 6pm through the next day reaches it.
        </EmptyState>
      </div>
    );
  }
  return (
    <>
      {unlocated.length > 0 && (
        <div className="callout callout-danger">
          <Icon name="alert" size={20} />
          <div className="grow">
            {unlocated.length === 1 ? `${customer(unlocated[0]!)} has no map location, so its forecast is never checked.` : `${unlocated.length} snow customers have no map location, so their forecasts are never checked.`} Fix the address on the property.
          </div>
        </div>
      )}
      <div className="toolbar">
        <div className="input-group">
          <span className="addon"><Icon name="search" size={16} /></span>
          <input className="input" type="search" placeholder="Search by customer, address or crew" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search snow customers" />
        </div>
      </div>
      {rows.length === 0 ? (
        <div className="card"><EmptyState icon="search" title="Nothing matches" action={<Button onClick={() => setSearch("")}>Clear search</Button>} /></div>
      ) : (
        <div className="card">
          <table className="table table-stack">
            <thead><tr><th>Customer</th><th>Plow and salt</th><th>Service</th><th>Crew and people</th><th>A storm bills</th></tr></thead>
            <tbody>
              {rows.map((s) => {
                const people = s.people.map((p) => nameOf(members.get(p.user_id)));
                const prices = tiersOf(s).length;
                return (
                  <tr key={s.job_id} className="row-link" onClick={() => onOpen(s.job_id)}>
                    <td>
                      <Link className="cell-link" to={`/snow?tab=customers&open=${s.job_id}`} replace onClick={(e) => e.stopPropagation()}>{customer(s)}</Link>
                      <div className="muted small">{addressLine(s.job.property) || s.job.title}</div>
                      {s.job.paused_at ? <div style={{ marginTop: 4 }}><StatusPill label="Paused" tone="muted" /></div> : !located(s) && <div style={{ marginTop: 4 }}><StatusPill label="No map location" tone="danger" /></div>}
                    </td>
                    <td className="tabular">
                      Plow at {inches(Number(s.trigger_in))}
                      <div className="muted small">
                        {[s.salt_trigger_in != null ? `Salt at ${inches(Number(s.salt_trigger_in))}` : "No salting", s.repeat_in != null && `again every ${inches(Number(s.repeat_in))}`].filter(Boolean).join(", ")}
                      </div>
                    </td>
                    <td>
                      {s.clear_by ? `Clear by ${clockText(s.clear_by)}` : <span className="muted">No set time</span>}
                      <div className="muted small">{[s.priority === 1 && "First priority", s.priority === 3 && "After the others", s.tell_client && "Customer is told"].filter(Boolean).join(" · ")}</div>
                    </td>
                    <td>
                      {s.job.crew?.name ?? (people.length ? people.join(", ") : <span className="text-danger">No one assigned</span>)}
                      {s.job.crew && people.length > 0 && <div className="muted small">{people.join(", ")}</div>}
                    </td>
                    <td>
                      {prices ? `By depth, ${prices} ${prices === 1 ? "price" : "prices"}` : "The job's price, each push"}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <div className="list-foot"><span>{rows.length} snow {rows.length === 1 ? "customer" : "customers"}</span></div>
        </div>
      )}
    </>
  );
}
