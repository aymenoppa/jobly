import { visitPrice } from "@jobly/core/promos";
import { profitAlertPercent } from "@jobly/core/reports";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useDeferredValue, useEffect, useState, type FormEvent } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { ClientLink } from "@/components/ui/ClientPreview";
import { choose, confirm } from "@/components/ui/Confirm";
import { RowMenu } from "@/components/ui/ContextMenu";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { PageHeader } from "@/components/ui/PageHeader";
import { Select } from "@/components/ui/Select";
import { archiveWithUndo, SelectAllCell, SelectCell, SelectionBar, useHoldToPick, useSelection } from "@/components/ui/Selection";
import { ListPageSkeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { EntityStatus } from "@/components/ui/StatusPill";
import { api, searchTerm, supabase, unwrap } from "@/lib/api";
import { BULK_CHUNK, bulkOutcome, inChunks, reportBulk, type BulkResult } from "@/lib/bulk";
import { errorMessage } from "@/lib/errors";
import { addDaysIso, formatDate, formatMoney, todayIn } from "@/lib/format";
import { titleOrClientFilter, useStatusCounts } from "@/lib/listing";
import { firstRows } from "@/lib/paging";
import { can, hasRole, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { useSchedulingRights } from "../schedule/myCrews";
import { snowJobs } from "../snow/snowData";
import { ChangePricesDialog } from "./ChangePricesDialog";
import { NewJobDialog, useCrews } from "./JobDialogs";

/** Each tab's job_state values: an active job's is late, today, upcoming, unscheduled or paused, another job's is its status. */
const FILTERS = [
  { key: "active", label: "Active", states: ["late", "today", "upcoming", "unscheduled"] },
  { key: "late", label: "Late", states: ["late"] },
  { key: "today", label: "Today", states: ["today"] },
  { key: "upcoming", label: "Upcoming", states: ["upcoming"] },
  { key: "unscheduled", label: "Unscheduled", states: ["unscheduled"] },
  { key: "paused", label: "Paused", states: ["paused"] },
  { key: "invoice", label: "Requires invoicing", states: ["requires_invoicing"] },
  { key: "completed", label: "Completed", states: ["completed"] },
  { key: "archived", label: "Archived", states: ["archived"] },
] as const;
type FilterKey = (typeof FILTERS)[number]["key"];
const JOB_COLUMNS = "id, number, title, job_state, kind, default_crew_id, pricing, invoice_schedule, financials:job_financials(contract_total), lines:job_line_items(quantity, unit_price, discount_billing), client:clients(id, display_name), property:properties(line1, city), visits(id, status, scheduled_on)";
const BELOW_COLUMNS = "profit_alert:job_profit_alerts!inner(below)";
/** Below your margin lists jobs in every state but archived. */
const BELOW_STATES = FILTERS.filter((f) => f.key !== "active" && f.key !== "archived").flatMap((f) => f.states);
/** How many jobs the list shows at first, and how many more each "Load more" brings. */
const PAGE = 200;
const plural = (n: number, one: string) => `${n} ${n === 1 ? one : `${one}s`}`;

/**
 * The first `limit` jobs in some states, newest first, and how many there are in all (`total`).
 * `term` narrows them to a job number, or a title or client that has it; `kind` to one-off or recurring.
 */
export async function loadJobs({ companyId, states, kind, term, below = false }: { companyId: string; states: readonly string[]; kind: "" | "one_off" | "recurring"; term: string; below?: boolean }, limit: number) {
  const match = term && !/^\d+$/.test(term) ? await titleOrClientFilter(companyId, term) : null;
  // Below your margin: only the jobs the hourly profit check last found below the company's line.
  const columns = (below ? `${JOB_COLUMNS}, ${BELOW_COLUMNS}` : JOB_COLUMNS) as typeof JOB_COLUMNS;
  const { rows, total } = await firstRows(
    () => {
      let q = supabase()
        .from("jobs")
        .select(columns, { count: "exact" })
        .eq("company_id", companyId)
        .in("job_state", [...(below ? BELOW_STATES : states)]);
      if (below) q = q.eq("profit_alert.below" as "id", true as never);
      if (kind) q = q.eq("kind", kind);
      if (term) q = match ? q.or(match) : q.eq("number", Number(term));
      return q;
    },
    limit,
    { order: { column: "created_at", ascending: false } },
  );
  return { rows, total: total ?? rows.length };
}

/** What an empty filter says, in the filter's own words. */
const EMPTY_TITLES: Record<FilterKey, string> = {
  active: "No active jobs", late: "No late jobs", today: "No jobs today", upcoming: "No upcoming jobs", unscheduled: "No unscheduled jobs",
  paused: "No paused jobs", invoice: "No jobs to invoice", completed: "No completed jobs", archived: "No archived jobs",
};

export function JobsPage() {
  const session = useSession();
  const { company } = session;
  const navigate = useNavigate();
  const [params, setParams] = useSearchParams();
  const [filter, setFilter] = useState<FilterKey>(() => (FILTERS.find((x) => x.key === params.get("status"))?.key as FilterKey | undefined) ?? "active");
  const [kind, setKind] = useState<"" | "one_off" | "recurring">("");
  const [search, setSearch] = useState("");
  const term = useDeferredValue(searchTerm(search));
  const states = FILTERS.find((f) => f.key === filter)!.states;
  const canSell = hasRole(session, "admin", "office", "estimator") && can(session, "sales");
  const counts = useStatusCounts("jobs", company.id, Object.fromEntries(FILTERS.map((f) => [f.key, f.states])), "job_state");
  const today = todayIn(company.timezone);
  const queryClient = useQueryClient();
  const [assigning, setAssigning] = useState(false);
  const [pausing, setPausing] = useState(false);
  const canDispatch = useSchedulingRights().canDispatch;
  // Change prices across repeating jobs: the office with Quotes and sales (the database checks the same).
  const canChangePrices = hasRole(session, "admin", "office") && can(session, "sales");
  const [pricing, setPricing] = useState(false);
  const [limit, setLimit] = useState(PAGE);
  // Below your margin: for the people who see job costs, while the company has a profit line.
  const seesMargins = hasRole(session, "admin", "office") && can(session, "job_costs") && profitAlertPercent(company.settings) !== null;
  const [below, setBelow] = useState(() => params.get("margin") === "below");
  const showBelow = seesMargins && below;
  // The note after the margin changes links here, maybe from the Jobs page itself.
  useEffect(() => { if (params.get("margin") === "below") setBelow(true); }, [params]);
  useEffect(() => setLimit(PAGE), [filter, kind, term, showBelow]);
  const belowCount = useQuery({
    queryKey: ["jobs", company.id, "below-margin"],
    enabled: seesMargins,
    queryFn: async () => {
      const { count, error } = await supabase().from("job_profit_alerts").select("job_id, job:jobs!inner(status)", { count: "exact", head: true }).eq("company_id", company.id).eq("below", true).neq("job.status", "archived");
      if (error) throw error;
      return count ?? 0;
    },
  });
  const pickFilter = (key: FilterKey) => {
    setFilter(key);
    setBelow(false);
  };

  const listKey = ["jobs", company.id, showBelow ? "below" : filter, kind, term, limit];
  const jobs = useQuery({
    queryKey: listKey,
    placeholderData: keepPreviousData,
    queryFn: () => loadJobs({ companyId: company.id, states, kind, term, below: showBelow }, limit),
  });

  // Picking several: archiving them, pausing and resuming them, and setting their crew, as a job's menu and details do.
  const selection = useSelection(canSell ? (jobs.data?.rows ?? []).map((j) => j.id) : [], `${showBelow ? "below" : filter}|${kind}|${term}`);
  const hold = useHoldToPick(selection);

  if (jobs.isPending) return <ListPageSkeleton columns={5} tabs={FILTERS.length} />;
  const rows = jobs.data?.rows ?? [];
  const total = jobs.data?.total ?? 0;
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["jobs", company.id] });
  // Of the picked: the repeating jobs that are active, which can pause, and the ones paused, which can resume.
  const picked = rows.filter((j) => selection.has(j.id));
  const canPause = picked.filter((j) => j.kind === "recurring" && (FILTERS[0].states as readonly string[]).includes(j.job_state ?? ""));
  const paused = picked.filter((j) => j.job_state === "paused");
  /** The picked jobs that are paused start again, as Resume job on each one's page. */
  const resume = async () => {
    const numbers = new Map(paused.map((j) => [j.id, j.number]));
    if (!(await confirm({ title: `Resume ${plural(paused.length, "job")}?`, body: "Their visits go back on the schedule from today.", confirmLabel: "Resume" }))) return;
    selection.clear();
    const result = await inChunks([...numbers.keys()], async (chunk) => unwrap(await supabase().from("jobs").update({ paused_at: null }).in("id", chunk).not("paused_at", "is", null).select("id")).map((j) => j.id));
    if (canDispatch) await remakeVisits(result.done);
    reportBulk(result, { verb: "resumed", one: "job", many: "jobs", name: (id) => `#${numbers.get(id) ?? "?"}` }, { tone: "job" });
    void refresh();
  };
  const archive = async () => {
    const ids = selection.ids;
    const numbers = new Map(rows.map((j) => [j.id, j.number]));
    if (!(await confirm({ title: `Archive ${plural(ids.length, "job")}?`, body: "They move to Archived, and a recurring job's upcoming visits come off the schedule. Each can be reopened from its page.", confirmLabel: "Archive" }))) return;
    selection.clear();
    archiveWithUndo<{ rows: typeof rows; total: number }>({
      key: listKey,
      ids,
      title: `${plural(ids.length, "job")} archived`,
      tone: "job",
      // Only the Archived tab shows archived jobs, and Archive isn't offered there.
      hide: (d, gone) => ({ rows: d.rows.filter((j) => !gone.has(j.id)), total: d.total - d.rows.filter((j) => gone.has(j.id)).length }),
      write: async (chunk) => unwrap(await supabase().from("jobs").update({ status: "archived" }).in("id", chunk).neq("status", "archived").select("id")).map((j) => j.id),
      words: { verb: "archived", one: "job", many: "jobs", name: (id) => `#${numbers.get(id) ?? "?"}` },
      refresh,
    });
  };

  return (
    <>
      <PageHeader
        title="Jobs"
        actions={
          <>
            {canChangePrices && <Button icon="dollar" onClick={() => setPricing(true)}>Change prices</Button>}
            {canSell && <Button variant="primary" icon="plus" onClick={() => setParams({ new: "1" }, { replace: true })}>New job</Button>}
          </>
        }
      />
      <div className="toolbar">
        <div className="input-group">
          <span className="addon"><Icon name="search" size={16} /></span>
          <input className="input" type="search" placeholder="Search by title, client or #number" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search jobs" />
        </div>
        <div className="tabs" role="group" aria-label="Filter jobs">
          {FILTERS.map((f) => (
            <button key={f.key} type="button" className="tab" aria-pressed={!showBelow && filter === f.key} onClick={() => pickFilter(f.key)}>
              {f.label}
              {counts.data && <span className="badge">{counts.data[f.key]}</span>}
            </button>
          ))}
          {/* Jobs the hourly profit check found below the company's line, in any state but archived. */}
          {seesMargins && (showBelow || (belowCount.data ?? 0) > 0) && (
            <button type="button" className="tab" aria-pressed={showBelow} onClick={() => setBelow(!showBelow)}>
              Below your margin
              {belowCount.data !== undefined && <span className="badge">{belowCount.data}</span>}
            </button>
          )}
        </div>
        <Select className="select" style={{ width: "auto" }} value={kind} onChange={(e) => setKind(e.target.value as typeof kind)} aria-label="Job type">
          <option value="">One-off and recurring</option>
          <option value="one_off">One-off only</option>
          <option value="recurring">Recurring only</option>
        </Select>
      </div>
      {jobs.error && !jobs.data ? (
        <div className="card"><ErrorState error={jobs.error} onRetry={() => jobs.refetch()} /></div>
      ) : rows.length === 0 ? (
        <div className="card">
          {term || kind ? (
            <EmptyState icon="search" title="No jobs match" action={<Button onClick={() => { setSearch(""); setKind(""); }}>Clear filters</Button>} />
          ) : showBelow ? (
            <EmptyState icon="job" title="No jobs below your margin" />
          ) : (
            // New job is the page header's green button, so the empty state points to quotes instead of repeating it.
            <EmptyState icon="job" title={EMPTY_TITLES[filter]} action={canSell && filter === "active" && <Link className="btn" to="/quotes">Go to quotes</Link>}>
              {filter !== "active" ? null : canSell ? "Jobs come from approved quotes. For work that doesn't need one, create the job directly with New job." : "Jobs come from approved quotes."}
            </EmptyState>
          )}
        </div>
      ) : (
        <div className={`card${jobs.isPlaceholderData ? " is-stale" : ""}`}>
          {canSell && (
            <SelectionBar selection={selection} noun="jobs">
              <Button size="sm" icon="users" onClick={() => setAssigning(true)}>Assign crew</Button>
              {canPause.length > 0 && <Button size="sm" icon="pause" onClick={() => setPausing(true)}>Pause</Button>}
              {paused.length > 0 && <Button size="sm" icon="play" onClick={() => void resume()}>Resume</Button>}
              {filter !== "archived" && <Button size="sm" icon="archive" onClick={() => void archive()}>Archive</Button>}
            </SelectionBar>
          )}
          <table className="table table-stack">
            <thead><tr>{canSell && <SelectAllCell selection={selection} label="Select all jobs on this page" />}<th>#</th><th>Job</th><th>Next visit</th>{canSell && <th className="num">Value</th>}<th>Status</th></tr></thead>
            <RowMenu href={(id) => `/jobs/${id}`} selection={selection} {...(canSell ? hold : {})}>
              {rows.map((j) => {
                const open = j.visits.filter((v) => !["completed", "cancelled"].includes(v.status));
                const next = open.filter((v) => v.scheduled_on && v.scheduled_on >= today).sort((a, b) => a.scheduled_on!.localeCompare(b.scheduled_on!))[0];
                const late = open.filter((v) => v.scheduled_on && v.scheduled_on < today).length;
                const done = j.visits.filter((v) => v.status === "completed").length;
                return (
                  <tr key={j.id} className="row-link" data-row={j.id} data-selected={selection.has(j.id) || undefined} onClick={() => navigate(`/jobs/${j.id}`)}>
                    {canSell && <SelectCell selection={selection} id={j.id} label={`Select job #${j.number}`} />}
                    <td className="muted tabular" style={{ width: 56 }}>#{j.number}</td>
                    <td>
                      <Link className="cell-link" to={`/jobs/${j.id}`} onClick={(e) => e.stopPropagation()}>{j.title}</Link>
                      <div className="muted small">{j.client && <ClientLink id={j.client.id} name={j.client.display_name} />}{j.property ? ` · ${j.property.line1}` : ""}</div>
                    </td>
                    <td>
                      {next?.scheduled_on ? formatDate(next.scheduled_on) : <span className="muted">—</span>}
                      <div className="small">
                        <span className="muted">{done}/{j.visits.length} done{j.kind === "recurring" ? " · recurring" : ""}</span>
                        {late > 0 && <span className="text-danger strong"> · {late} overdue</span>}
                      </div>
                    </td>
                    {/* A visit's price: a once-per-job promo code comes off the first invoice only, not every visit. A fixed price is the plan's. */}
                    {canSell && (
                      <td className="num">
                        {j.kind === "recurring" && j.pricing === "fixed" ? <span className="muted small">{formatMoney(j.financials?.contract_total ?? 0)}{j.invoice_schedule === "monthly" ? "/month" : ""}</span>
                          : j.kind === "recurring" ? <span className="muted small">{formatMoney(visitPrice(j.financials?.contract_total, j.lines))}/visit</span>
                            : formatMoney(j.financials?.contract_total ?? 0)}
                      </td>
                    )}
                    <td><EntityStatus kind="job" status={j.job_state ?? "active"} /></td>
                  </tr>
                );
              })}
            </RowMenu>
          </table>
          <div className="list-foot">
            <span>{rows.length < total ? `Showing ${rows.length} of ${total}` : plural(rows.length, "job")}</span>
            {rows.length < total && <Button size="sm" loading={jobs.isFetching} onClick={() => setLimit((l) => l + PAGE)}>Load more</Button>}
          </div>
        </div>
      )}
      <NewJobDialog open={params.get("new") === "1"} onClose={() => setParams({}, { replace: true })} onCreated={(id) => navigate(`/jobs/${id}`)} />
      {pricing && <ChangePricesDialog picked={selection.ids} onClose={() => setPricing(false)} onChanged={() => void refresh()} />}
      {pausing && (
        <PauseJobsDialog
          jobs={canPause}
          left={picked.length - canPause.length}
          canSchedule={canDispatch}
          onClose={() => setPausing(false)}
          onDone={() => {
            setPausing(false);
            selection.clear();
            void refresh();
          }}
        />
      )}
      {assigning && (
        <AssignCrewDialog
          jobs={rows.filter((j) => selection.has(j.id))}
          onClose={() => setAssigning(false)}
          onDone={() => {
            setAssigning(false);
            selection.clear();
            void refresh();
          }}
        />
      )}
    </>
  );
}

/** Upcoming visits refreshed at once: each is one call that works out the job's whole schedule. */
const VISIT_CALLS = 4;

/** These jobs' visits brought in line with their schedules now (generate-visits). One that fails is left to the nightly run, which does the same. */
async function remakeVisits(jobIds: readonly string[]) {
  for (let i = 0; i < jobIds.length; i += VISIT_CALLS) await Promise.allSettled(jobIds.slice(i, i + VISIT_CALLS).map((id) => api.post(`/jobs/${id}/generate-visits`)));
}

/**
 * Pause the picked jobs at once (the mowing season is over), as Pause job on each one's page:
 * upcoming visits come off and nothing is made or billed until they resume, by hand or on the day
 * given. `jobs` are the picked ones that can pause, repeating and active; `left` how many picked
 * can't. Snow customers among them are left out: Snow doesn't check a paused job, which is rarely
 * what ending a season means, so one of those is paused from its own page, where it says so.
 */
function PauseJobsDialog({ jobs, left, canSchedule, onClose, onDone }: { jobs: Array<{ id: string; number: number | null }>; left: number; canSchedule: boolean; onClose: () => void; onDone: () => void }) {
  const { company } = useSession();
  const tomorrow = addDaysIso(todayIn(company.timezone), 1);
  const [resumeOn, setResumeOn] = useState("");
  const name = (id: string) => `#${jobs.find((j) => j.id === id)?.number ?? "?"}`;
  const snow = useQuery({ queryKey: ["snow", company.id, "jobs", jobs.map((j) => j.id)], queryFn: () => snowJobs(jobs.map((j) => j.id)) });
  const kept = jobs.filter((j) => snow.data?.has(j.id));
  const going = jobs.filter((j) => !snow.data?.has(j.id));
  const pause = useMutation({
    meta: { inline: true },
    mutationFn: async () => {
      const result = await inChunks(going.map((j) => j.id), async (chunk) =>
        unwrap(await supabase().from("jobs").update({ paused_at: new Date().toISOString(), resume_on: resumeOn || null }).in("id", chunk).eq("kind", "recurring").eq("status", "active").is("paused_at", null).select("id")).map((j) => j.id));
      // Without the right to schedule the team, the nightly run takes the visits off.
      if (canSchedule) await remakeVisits(result.done);
      return result;
    },
    onSuccess: (result) => {
      reportBulk(result, { verb: "paused", one: "job", many: "jobs", name }, { tone: "job" });
      onDone();
    },
  });
  return (
    <Dialog open onClose={onClose} title="Pause jobs" description="Upcoming visits come off the schedule, and no visits, monthly invoices or plan charges are made while they're paused. Visits with work logged stay.">
      <form onSubmit={(e: FormEvent) => { e.preventDefault(); if (snow.data && going.length) pause.mutate(); }}>
        <Field label="Resume on" optional hint="The day they start again by themselves, like the first day of next season. Leave it empty to resume them yourself.">
          <input className="input" type="date" value={resumeOn} min={tomorrow} onChange={(e) => setResumeOn(e.target.value)} />
        </Field>
        {kept.length > 0 && (
          <div className="callout callout-warning" role="status">
            {kept.length === 1 ? `Job ${name(kept[0]!.id)} is a snow customer and is left out.` : `${kept.length} snow customers are left out (${kept.slice(0, 5).map((j) => name(j.id)).join(", ")}${kept.length > 5 ? ` and ${kept.length - 5} more` : ""}).`} Snow doesn't check a paused job. To pause one anyway, use Pause job on its own page.
          </div>
        )}
        {left > 0 && <span className="muted small" role="status">{plural(left, "job")} picked {left === 1 ? "isn't" : "aren't"} paused: only repeating jobs that are active can be.</span>}
        <FormError error={pause.error ?? snow.error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" icon="pause" loading={pause.isPending} disabled={!snow.data || !going.length}>
            {snow.data && !going.length ? "Nothing to pause" : `Pause ${plural(snow.data ? going.length : jobs.length, "job")}`}
          </Button>
        </div>
      </form>
    </Dialog>
  );
}

/**
 * One crew for the picked jobs (default_crew_id), as a job's details set it. A recurring job's
 * visits already on the schedule keep their crew unless the office says to change them too (the
 * question the details dialog asks), and then the server moves them (generate-visits, upcoming).
 */
function AssignCrewDialog({ jobs, onClose, onDone }: { jobs: Array<{ id: string; number: number | null; kind: string; default_crew_id: string | null }>; onClose: () => void; onDone: () => void }) {
  const { company } = useSession();
  const crews = useCrews();
  // "" until one is chosen, so nothing is taken off its crew by accident; "none" for No crew.
  const [crewId, setCrewId] = useState("");
  const target = crewId === "none" ? null : crewId;
  // Only those it changes: a job on that crew already stays as it is.
  const changing = crewId ? jobs.filter((j) => j.default_crew_id !== target) : [];
  const crewName = crews.data?.find((c) => c.id === target)?.name;
  const assign = useMutation({
    meta: { inline: true },
    mutationFn: async () => {
      const today = todayIn(company.timezone);
      const recurring = changing.filter((j) => j.kind === "recurring").map((j) => j.id);
      let count = 0;
      for (let i = 0; i < recurring.length; i += BULK_CHUNK) {
        const { count: n, error } = await supabase()
          .from("visits")
          .select("id", { count: "exact", head: true })
          .in("job_id", recurring.slice(i, i + BULK_CHUNK))
          .eq("status", "scheduled")
          .not("recurrence_key", "is", null)
          .gte("scheduled_on", today);
        if (error) throw error;
        count += n ?? 0;
      }
      // Both buttons go ahead; closing the question (Escape, the X) changes nothing, as in the details dialog.
      let upcoming = false;
      if (count) {
        const one = count === 1;
        const choice = await choose({
          title: one ? "Change the upcoming visit too?" : `Change the ${count} upcoming visits too?`,
          body: `${one ? "It's" : "They're"} already on the schedule with the old crew. Change ${one ? "it" : "them"} too, and ${crewName ? `${one ? "it goes" : "they go"} to ${crewName}` : `${one ? "it has" : "they have"} no crew`}. Visits that are done or started stay as they are.`,
          confirmLabel: one ? "Change it too" : "Change them too",
          cancelLabel: "Only new visits",
        });
        if (choice === null) return null;
        upcoming = choice;
      }
      const result = await inChunks(changing.map((j) => j.id), async (chunk) => unwrap(await supabase().from("jobs").update({ default_crew_id: target }).in("id", chunk).select("id")).map((j) => j.id));
      const visits: BulkResult = { done: [], failed: [] };
      const moved = upcoming ? recurring.filter((id) => result.done.includes(id)) : [];
      for (let i = 0; i < moved.length; i += VISIT_CALLS) {
        await Promise.all(
          moved.slice(i, i + VISIT_CALLS).map((id) =>
            api.post(`/jobs/${id}/generate-visits`, { upcoming: true }).then(
              () => visits.done.push(id),
              (error) => visits.failed.push({ id, reason: errorMessage(error) }),
            ),
          ),
        );
      }
      return { result, visits };
    },
    onSuccess: (r) => {
      if (!r) return;
      const numbers = new Map(jobs.map((j) => [j.id, j.number]));
      const name = (id: string) => `#${numbers.get(id) ?? "?"}`;
      reportBulk(r.result, { verb: crewName ? `assigned to ${crewName}` : "unassigned", one: "job", many: "jobs", name }, { tone: "job" });
      // The crew is set either way; say which jobs' visits kept the old one, and why.
      const visits = bulkOutcome(r.visits, { verb: "changed", one: "job", many: "jobs", name }, true);
      if (visits) toast.warning(`Upcoming visits kept the old crew on ${plural(r.visits.failed.length, "job")}`, { description: visits.description, tone: "job" });
      onDone();
    },
  });
  return (
    <Dialog open onClose={onClose} title="Assign a crew" description={`For the ${plural(jobs.length, "job")} picked. New visits go to this crew.`}>
      <form onSubmit={(e: FormEvent) => { e.preventDefault(); if (changing.length) assign.mutate(); }}>
        <Field label="Crew">
          <Select className="select" value={crewId} onChange={(e) => setCrewId(e.target.value)} required>
            <option value="" disabled>Choose a crew</option>
            <option value="none">No crew</option>
            {crews.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </Select>
        </Field>
        {crewId && changing.length < jobs.length && (
          <span className="muted small" role="status">
            {changing.length ? `${plural(jobs.length - changing.length, "job")} ${jobs.length - changing.length === 1 ? "is" : "are"} ${target ? "on that crew" : "without a crew"} already.` : `They're all ${target ? "on that crew" : "without a crew"} already.`}
          </span>
        )}
        <FormError error={assign.error ?? crews.error} />
        <div className="form-actions">
          <Button onClick={onClose}>Cancel</Button>
          <Button type="submit" variant="primary" icon="users" loading={assign.isPending} disabled={!changing.length}>
            {changing.length ? `Assign to ${plural(changing.length, "job")}` : "Assign crew"}
          </Button>
        </div>
      </form>
    </Dialog>
  );
}
