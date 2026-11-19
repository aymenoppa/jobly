/**
 * Snow → Storm: the storm, and what's left to do about it. On top, the snow coming from 6pm today
 * through tomorrow on a sky the color of the weather (as the weather popup is, SnowWeather.tsx): how
 * much at the customers, when it falls hour by hour at the shop (or at a customer picked there), and
 * the official winter alerts in force. Under it, a storm
 * that's here today: how far along each customer's visits are, and any customer it now calls for
 * that nobody scheduled, to schedule for today. Then the storm coming, counted
 * and piled by what the office still has to do: to schedule, to check, scheduled, and not this storm
 * (storm.ts), which the business can have Snow do by itself: the switch at the foot schedules each
 * storm as its people are told (set_snow_auto_schedule). A subcontractor's answer to "can you go out?" sits beside their name on the customers
 * they work. A customer's row opens it in a popup: its address, notes, photos and files
 * (SnowSiteDetails.tsx).
 */
import { clockText, snowPlan, type SnowPlan } from "@jobly/core/snow";
import { WEATHER_SOURCE_LABELS, type WeatherSource } from "@jobly/core/weather";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useDeferredValue, useState, type CSSProperties, type ReactNode } from "react";
import { Link } from "react-router-dom";
import { Bar, BarChart, XAxis, YAxis } from "recharts";
import { Button } from "@/components/ui/Button";
import { CHART_MOTION, ChartContainer, ChartTooltip, ChartTooltipContent } from "@/components/ui/Chart";
import { confirm } from "@/components/ui/Confirm";
import { Icon } from "@/components/ui/Icon";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState } from "@/components/ui/States";
import { EntityStatus, StatusPill, statusText } from "@/components/ui/StatusPill";
import { api, supabase, unwrap } from "@/lib/api";
import { addDaysIso, addressLine, formatDateTime, formatDay, todayIn } from "@/lib/format";
import { can, useSession } from "@/lib/session";
import { autoKey, customer, inches, loadAuto, located, nameOf, rulesOf, type Member, type Site } from "./snowData";
import { BACKDROPS, SHOP, SKY, SOURCE_LINKS, SkyArt, hasShop, hourLabel, snowStory, weatherQuery, when } from "./SnowWeather";
import { progressOf, standingOf, STORM_GROUPS, workText, type StormGroup } from "./storm";
import styles from "./StormBoard.module.css";

interface Alert { id: string; event: string; headline: string; area: string; severity: string; ends: string | null; description: string }
/** Tomorrow's storm at each customer by job (`inches`, for `date`), and today's own: what has fallen since 6pm last night and what's still coming by 6pm tonight. */
interface Forecast { date: string; source: WeatherSource; inches: Record<string, number | null>; alerts: Alert[]; today?: { date: string; inches: Record<string, number | null> } }

/** "Anchorage; Portage; Skilak Lake; ..." as its first two places and how many more: an alert can name a dozen. */
function areas(area: string): string {
  const places = area.split(";").map((p) => p.trim()).filter(Boolean);
  return places.length > 2 ? `${places.slice(0, 2).join(", ")} and ${places.length - 2} more` : places.join(", ");
}

const GROUP_TITLES: Record<StormGroup, string> = { schedule: "To schedule", check: "Needs a look", scheduled: "Scheduled", off: "Not this storm" };
/** Who works a customer: its crew's lead and members, and the people listed on it. */
const workers = (s: Site) => new Set([s.job.crew?.lead_user_id, ...(s.job.crew?.members ?? []).map((m) => m.user_id), ...s.people.map((p) => p.user_id)].filter((id): id is string => Boolean(id)));
/** First priority first, then the earliest promise, then by name. */
const inOrder = (a: Site, b: Site) => a.priority - b.priority || (a.clear_by ?? "99").localeCompare(b.clear_by ?? "99") || customer(a).localeCompare(customer(b));

const TODAY_FIELDS = "job_id, kind, pushes, job:jobs!inner(title, client:clients(display_name), property:properties(line1, city)), visits:snow_visits(visit:visits(id, status))";

export function StormBoard({ sites: all, team, onOpen, onWeather }: { sites: Site[]; team: Member[]; onOpen: (jobId: string) => void; onWeather: (place: string) => void }) {
  const session = useSession();
  const { company } = session;
  const queryClient = useQueryClient();
  const [search, setSearch] = useState("");
  const term = useDeferredValue(search.trim().toLowerCase());
  const members = new Map(team.map((m) => [m.user_id, m]));
  const forecast = useQuery({ queryKey: ["snow", company.id, "forecast"], staleTime: 30 * 60_000, queryFn: () => api.get<Forecast>("/snow/forecast") });
  const date = forecast.data?.date;
  // The storm's visits for tomorrow, by job: they read Scheduled, and aren't scheduled twice.
  const booked = useQuery({
    enabled: Boolean(date),
    queryKey: ["snow", company.id, "booked", date],
    queryFn: async () => {
      const rows = unwrap(await supabase().from("snow_visits").select("job_id, visit:visits!inner(status)").eq("company_id", company.id).eq("snow_date", date!).neq("visit.status", "cancelled"));
      return rows.reduce<Record<string, number>>((count, r) => ({ ...count, [r.job_id]: (count[r.job_id] ?? 0) + 1 }), {});
    },
  });
  // The subcontractors asked whether they can go out tomorrow, and what each said.
  const asked = useQuery({
    enabled: Boolean(date),
    queryKey: ["snow", company.id, "availability", date],
    queryFn: async () => unwrap(await supabase().from("snow_availability").select("user_id, can").eq("company_id", company.id).eq("snow_date", date!)),
  });
  const answers = new Map((asked.data ?? []).map((a) => [a.user_id, a.can]));
  // Whether storms schedule themselves as people are told, and the switch for it.
  const auto = useQuery({ queryKey: autoKey(company.id), queryFn: () => loadAuto(company.id) });
  const setAuto = useMutation({
    meta: { success: (on: boolean) => (on ? "Storms schedule themselves from now on" : "Storms wait for you to schedule them") },
    mutationFn: async (on: boolean) => unwrap(await supabase().rpc("set_snow_auto_schedule", { p_company: company.id, p_on: on })),
    onSuccess: (on) => queryClient.setQueryData(autoKey(company.id), on),
  });

  const rows = all.map((site) => {
    const snow = forecast.data?.inches[site.job_id] ?? null;
    const visits = booked.data?.[site.job_id] ?? 0;
    return { site, snow, visits, standing: standingOf({ paused: Boolean(site.job.paused_at), located: located(site), rules: rulesOf(site), told: site.alerted_on === date }, snow, visits, auto.data) };
  });
  type Row = (typeof rows)[number];
  const pile = (group: StormGroup) => rows.filter((r) => r.standing.group === group);
  const toSchedule = pile("schedule");
  const shown = rows
    .filter(({ site: s }) => !term || [customer(s), s.job.title, addressLine(s.job.property), s.job.crew?.name].some((v) => v?.toLowerCase().includes(term)))
    .sort((a, b) => inOrder(a.site, b.site));

  const schedule = useMutation({
    meta: { success: (r: { created: number }) => (r.created ? `Scheduled ${r.created} ${r.created === 1 ? "visit" : "visits"} for tomorrow` : "They were scheduled already") },
    mutationFn: () => api.post<{ created: number }>("/snow/schedule", { job_ids: toSchedule.map((r) => r.site.job_id) }),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ["schedule"] });
      queryClient.invalidateQueries({ queryKey: ["snow", company.id] });
    },
  });
  const visitsToGo = toSchedule.reduce((n, r) => n + r.standing.plan!.pushes - r.visits, 0);
  const scheduleThem = async () => {
    const ok = await confirm({
      title: `Schedule ${toSchedule.length === 1 ? customer(toSchedule[0]!.site) : `${toSchedule.length} customers`} for tomorrow?`,
      body: `${visitsToGo === 1 ? "One visit" : `${visitsToGo} visits`} tomorrow, with each job's crew and people on them. They're told they're going out, and a customer set to be told hears it's coming.`,
      confirmLabel: "Schedule",
    });
    if (ok) schedule.mutate();
  };

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

  const scheduled = pile("scheduled");
  const check = pile("check");
  const off = pile("off");
  const yes = [...answers.values()].filter((a) => a === true).length;
  const no = [...answers].filter(([, a]) => a === false).map(([id]) => nameOf(members.get(id)));
  const waiting = [...answers.values()].filter((a) => a == null).length;

  /** A sub's answer beside their name; nothing for someone who wasn't asked. */
  const answer = (userId: string): ReactNode => {
    if (!answers.has(userId)) return null;
    const said = answers.get(userId);
    return said == null ? <span className="muted"> · no answer yet</span> : said ? <span className={styles.yes}> · can go</span> : <span className="text-danger"> · can't go</span>;
  };
  /** The crew, then the people listed and any sub on the crew who was asked, each with their answer. */
  const crewCell = (s: Site) => {
    const listed = s.people.map((p) => p.user_id);
    const people = [...listed, ...[...workers(s)].filter((id) => answers.has(id) && !listed.includes(id))];
    const names = people.map((id, i) => <span key={id}>{i > 0 && ", "}{nameOf(members.get(id))}{answer(id)}</span>);
    if (!s.job.crew) return people.length ? names : <span className="text-danger">No one assigned</span>;
    return <>{s.job.crew.name}{people.length > 0 && <div className="muted small">{names}</div>}</>;
  };

  const row = ({ site: s, snow, standing }: Row) => {
    const rules = rulesOf(s);
    // Room past the plow's trigger, so a bar that reaches it visibly passes the line.
    const full = Math.max(rules.trigger_in * 1.25, (snow ?? 0) * 1.1, 0.5);
    return (
      <tr key={s.job_id} className="row-link" onClick={() => onOpen(s.job_id)}>
        <td className={styles.who}>
          <Link className="cell-link" to={`/snow?open=${s.job_id}`} replace onClick={(e) => e.stopPropagation()}>{customer(s)}</Link>
          <div className="muted small">{addressLine(s.job.property) || s.job.title}</div>
        </td>
        <td>
          {snow == null ? <span className="muted">{located(s) && !s.job.paused_at ? "No forecast" : "—"}</span> : (
            <span className={styles.reading}>
              <Link className={`${styles.inches} tabular`} data-reached={standing.plan ? true : undefined} to={`/snow?weather=${s.job_id}`} replace title="See the weather here" onClick={(e) => e.stopPropagation()}>{inches(snow)}</Link>
              <span className={styles.gauge} aria-hidden="true">
                {snow > 0 && <span className={styles.fill} data-reached={standing.plan ? true : undefined} style={{ width: `${Math.min(100, (snow / full) * 100)}%` }} />}
                {rules.salt_trigger_in != null && <span className={styles.mark} data-salt style={{ left: `${(rules.salt_trigger_in / full) * 100}%` }} />}
                <span className={styles.mark} style={{ left: `${(rules.trigger_in / full) * 100}%` }} />
              </span>
            </span>
          )}
          <div className="muted small tabular">
            Plow at {inches(rules.trigger_in)}{rules.salt_trigger_in != null ? `, salt at ${inches(rules.salt_trigger_in)}` : ""}{rules.repeat_in != null ? `, again every ${inches(rules.repeat_in)}` : ""}
          </div>
        </td>
        <td className={standing.plan ? undefined : styles.blank}>
          {standing.plan ? <span className={styles.work}><Icon name={standing.plan.kind === "salt" ? "salt" : "truck"} size={16} />{workText(standing.plan)}</span> : <span className="muted">—</span>}
        </td>
        <td className={s.clear_by || s.priority !== 2 ? undefined : styles.blank}>
          {s.clear_by ? <span className="tabular"><span className={styles.phoneOnly}>Clear by </span>{clockText(s.clear_by)}</span> : s.priority === 2 && <span className="muted">—</span>}
          {s.priority !== 2 && <div className={s.clear_by ? "muted small" : "muted"} style={{ whiteSpace: "nowrap" }}>{s.priority === 1 ? "First priority" : "After the others"}</div>}
        </td>
        <td>{crewCell(s)}</td>
        <td className={styles.status}>
          {standing.tone ? <StatusPill label={standing.label} tone={standing.tone} /> : <span className="muted">{standing.label}</span>}
          {standing.note && <div className="muted small">{standing.note}</div>}
        </td>
      </tr>
    );
  };

  return (
    <>
      {forecast.error && !forecast.data ? (
        <div className="callout callout-danger">
          <Icon name="alert" size={20} />
          <div className="grow">Tomorrow's forecast couldn't be loaded, so this page can't say who it calls for. Their people are still told when it does.</div>
          <Button size="sm" onClick={() => forecast.refetch()} loading={forecast.isFetching}>Try again</Button>
        </div>
      ) : forecast.data ? (
        <Coming forecast={forecast.data} rows={rows} canChange={can(session, "settings")} onWeather={onWeather} />
      ) : (
        <div className="card card-pad"><Skeleton width="30%" /><Skeleton width="55%" /><Skeleton width="42%" /></div>
      )}
      {forecast.data && (
        <div className="stat-row">
          <div className="card stat">
            <div className="label">To schedule</div>
            <div className="value" style={toSchedule.length ? { color: "var(--warning)" } : undefined}>{toSchedule.length}</div>
            <div className="hint">{toSchedule.length ? `${visitsToGo} ${visitsToGo === 1 ? "visit" : "visits"} for tomorrow` : scheduled.length ? "Everyone it calls for is scheduled" : "Nothing reaches a trigger"}</div>
          </div>
          <div className="card stat">
            <div className="label">Scheduled</div>
            <div className="value">{scheduled.length}</div>
            <div className="hint">{scheduled.length ? `${scheduled.reduce((n, r) => n + r.visits, 0)} visits on tomorrow's schedule` : "No visits yet"}</div>
          </div>
          {check.length > 0 && (
            <div className="card stat">
              <div className="label">Needs a look</div>
              <div className="value" style={{ color: "var(--danger)" }}>{check.length}</div>
              <div className="hint">{[...new Set(check.map((r) => r.standing.label))].join(", ")}</div>
            </div>
          )}
          <div className="card stat">
            <div className="label">Not this storm</div>
            <div className="value">{off.length}</div>
            <div className="hint">Under their triggers, or paused</div>
          </div>
          {answers.size > 0 && (
            <div className="card stat">
              <div className="label">Subcontractors in</div>
              <div className="value">{yes} <span className={styles.of}>of {answers.size}</span></div>
              <div className="hint">{no.length ? `${no.join(", ")} can't go` : waiting ? `${waiting} yet to answer` : "All of them can go"}</div>
            </div>
          )}
        </div>
      )}
      <Today sites={all} crewCell={crewCell} snow={forecast.data?.today} onOpen={onOpen} />
      <div className="toolbar">
        <div className="input-group">
          <span className="addon"><Icon name="search" size={16} /></span>
          <input className="input" type="search" placeholder="Search by customer, address or crew" value={search} onChange={(e) => setSearch(e.target.value)} aria-label="Search snow customers" />
        </div>
      </div>
      {forecast.isPending ? (
        <div className="card card-pad"><Skeleton width="50%" /><Skeleton width="80%" /><Skeleton width="65%" /></div>
      ) : shown.length === 0 ? (
        <div className="card"><EmptyState icon="search" title="Nothing matches" action={<Button onClick={() => setSearch("")}>Clear search</Button>} /></div>
      ) : (
        <div className="card">
          {date && (
            <div className="card-head">
              <h2>Tomorrow</h2>
              <span className="muted small">6pm today through {formatDay(`${date}T12:00:00`)}</span>
            </div>
          )}
          <table className={`table table-stack ${styles.rows}`}>
            <thead><tr><th style={{ width: "23%" }}>Customer</th><th style={{ width: "21%" }}>Forecast</th><th style={{ width: "13%" }}>Work</th><th style={{ width: "13%" }}>Clear by</th><th style={{ width: "16%" }}>Crew and people</th><th style={{ width: "14%" }}>Status</th></tr></thead>
            {STORM_GROUPS.map((group) => {
              const mine = shown.filter((r) => r.standing.group === group);
              if (!mine.length) return null;
              return (
                <tbody key={group}>
                  <tr className={styles.group} data-group={group}>
                    <th colSpan={6} scope="rowgroup">
                      <span className={styles.groupHead}>
                        {forecast.data ? GROUP_TITLES[group] : "Snow customers"}
                        <span className={styles.count}>{mine.length}</span>
                        {group === "schedule" && booked.data && !term && (
                          <Button size="sm" variant="primary" icon="calendarCheck" loading={schedule.isPending} onClick={scheduleThem}>
                            {toSchedule.length === 1 ? "Schedule it" : `Schedule all ${toSchedule.length}`}
                          </Button>
                        )}
                      </span>
                    </th>
                  </tr>
                  {mine.map(row)}
                </tbody>
              );
            })}
          </table>
          <div className="list-foot"><span>{shown.length} snow {shown.length === 1 ? "customer" : "customers"}</span></div>
        </div>
      )}
      <div className="card card-pad">
        <label className="switch-row">
          <input type="checkbox" className="switch" checked={auto.data ?? false} disabled={auto.isPending || setAuto.isPending} onChange={(e) => setAuto.mutate(e.target.checked)} />
          <span>
            Schedule storms automatically
            <span className="muted small" style={{ display: "block", fontWeight: 400 }}>
              When the forecast calls for a customer, its visits go on the schedule as its crew is told: from 10am to 10pm the day before, and on the day for a storm that came up overnight. A customer set to be told hears it's coming. A visit you cancel isn't made again unless the storm grows. Off: you schedule each storm here.
            </span>
          </span>
        </label>
      </div>
      <p className="muted small">A storm is the snow from 6pm today through tomorrow, so one that comes in overnight counts whole.</p>
    </>
  );
}

/**
 * The snow coming, on its sky: how much at the customers, hour by hour at the shop (with no shop on
 * the map, where it's deepest), and the alerts in force. The weather pop-up picks another place.
 */
function Coming({ forecast, rows, canChange, onWeather }: { forecast: Forecast; rows: Array<{ site: Site; snow: number | null }>; canChange: boolean; onWeather: (place: string) => void }) {
  const { company } = useSession();
  const checked = rows.filter((r) => r.snow != null && !r.site.job.paused_at);
  const amounts = checked.map((r) => r.snow!);
  const most = Math.max(0, ...amounts);
  // Whose hours the sentence and the bars are: the shop's.
  const shop = hasShop(company);
  const places = rows.map((r) => r.site).filter(located).sort((a, b) => customer(a).localeCompare(customer(b)));
  const site = shop ? undefined : [...checked].sort((a, b) => b.snow! - a.snow!)[0]?.site ?? places[0];
  const at = site ? site.job_id : shop ? SHOP : null;
  const name = site ? customer(site) : "your shop";
  const weather = useQuery(weatherQuery(company.id, at));
  const w = weather.data;
  const snowing = most >= 0.05;
  const sky = snowing ? "snow" : w?.now.sky ?? "cloudy";
  const backdrop = BACKDROPS[SKY[sky].backdrop][w?.now.night ? "night" : "day"];
  // The storm's own hours: from 6pm today (or from now, once that's passed) to the end of tomorrow.
  const hours = (w?.hours ?? []).filter((h) => h.time >= `${addDaysIso(forecast.date, -1)}T18:00` && h.time < `${addDaysIso(forecast.date, 1)}T00:00`);
  const data = hours.map((h) => ({ time: h.time, at: when(h), snow: h.snow_in }));
  // Today's own storm there: what has fallen since 6pm last night and what's still coming by 6pm tonight
  // (at the shop, the forecast's own count of today, as the weather popup has it).
  const today = (site ? forecast.today?.inches[site.job_id] : w?.snow_by_day[addDaysIso(forecast.date, -1)]) || 0;
  return (
    <section className={styles.sky} style={{ "--sky-top": backdrop[0], "--sky-bottom": backdrop[1], "--sky-glow": backdrop[2] } as CSSProperties} aria-label="The snow coming">
      <div className={styles.coming}>
        <div className={styles.lead}>
          <SkyArt sky={sky} night={w?.now.night} size={84} moving />
          <div>
            <div className={styles.kicker}>At your customers, 6pm today through {formatDay(`${forecast.date}T12:00:00`)}</div>
            <div className={styles.amount}>{!amounts.length ? "No forecast" : !snowing ? "No snow" : Math.min(...amounts) > most - 0.05 ? inches(most) : `Up to ${inches(most)}`}</div>
            <div className={styles.story}>
              {at && <strong>At {name}: </strong>}
              {w ? `${today >= 0.05 ? `Today's snow: ${inches(today)}. ` : ""}${snowStory(w.hours)}` : weather.isPending && at ? <Skeleton width={220} /> : ""}
            </div>
          </div>
        </div>
        {at && data.some((d) => d.snow > 0) && (
          <div className={styles.hourly}>
            <ChartContainer config={{ snow: { label: "Snow that hour", color: "#fff" } }} label={`Snow each hour at ${name}, from 6pm today through tomorrow`} height={92}>
              <BarChart data={data} margin={{ top: 6, right: 4, bottom: 0, left: 4 }} barCategoryGap={2}>
                <XAxis dataKey="time" tickLine={false} axisLine={{ stroke: "rgba(255, 255, 255, 0.3)" }} tickMargin={6} ticks={data.filter((d) => Number(d.time.slice(11, 13)) % 6 === 0).map((d) => d.time)} tickFormatter={hourLabel} />
                <YAxis hide domain={[0, (max: number) => Math.max(0.1, max)]} />
                <ChartTooltip cursor={{ fill: "rgba(255, 255, 255, 0.12)" }} isAnimationActive={false} content={<ChartTooltipContent labelKey="at" format={inches} />} />
                <Bar dataKey="snow" fill="var(--color-snow)" fillOpacity={0.9} radius={[3, 3, 0, 0]} maxBarSize={14} {...CHART_MOTION} />
              </BarChart>
            </ChartContainer>
            <button type="button" className={styles.more} onClick={() => onWeather(at)}>Each hour at {name}<Icon name="chevronRight" size={14} /></button>
          </div>
        )}
      </div>
      {forecast.alerts.map((a) => (
        <details key={a.id} className={styles.alert}>
          <summary><Icon name="alert" size={16} />{a.event}{a.ends ? ` until ${formatDateTime(a.ends, company.timezone)}` : ""}{a.area ? ` · ${areas(a.area)}` : ""}</summary>
          <p style={{ whiteSpace: "pre-wrap" }}>{a.description || a.headline}</p>
          {a.area && <p className={styles.fine}>For {a.area}.</p>}
          <p className={styles.fine}>From the US National Weather Service.</p>
        </details>
      ))}
      <div className={styles.credit}>
        <span>Forecast by <a href={SOURCE_LINKS[forecast.source]} target="_blank" rel="noreferrer">{WEATHER_SOURCE_LABELS[forecast.source]}</a>{canChange && <> · <Link to="/settings?tab=weather">Change</Link></>}</span>
        {at && !data.some((d) => d.snow > 0) && (
          <button type="button" className={styles.more} onClick={() => onWeather(at)}>See the weather<Icon name="chevronRight" size={14} /></button>
        )}
      </div>
    </section>
  );
}

/**
 * Today's own storm: each customer it was scheduled for, with how far along its visits are, and any
 * customer today's snow calls for that has fewer visits than that (it came up overnight, or grew),
 * to schedule for today in one click. Nothing with no storm today.
 */
function Today({ sites, crewCell, snow, onOpen }: { sites: Site[]; crewCell: (s: Site) => ReactNode; snow: Forecast["today"]; onOpen: (jobId: string) => void }) {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const today = todayIn(company.timezone);
  const storm = useQuery({
    queryKey: ["snow", company.id, "today", today],
    refetchInterval: 60_000,
    queryFn: async () => unwrap(await supabase().from("snow_events").select(TODAY_FIELDS).eq("company_id", company.id).eq("snow_date", today).limit(1000)),
  });
  const clock = new Date().toLocaleTimeString("en-GB", { timeZone: company.timezone, hour: "2-digit", minute: "2-digit" });
  const logged = new Map((storm.data ?? []).map((e) => [e.job_id, e]));
  const rows = [...new Set([...logged.keys(), ...sites.map((s) => s.job_id)])].flatMap((jobId) => {
    const e = logged.get(jobId);
    const site = sites.find((s) => s.job_id === jobId);
    const visits = (e?.visits ?? []).flatMap((v) => (v.visit && v.visit.status !== "cancelled" ? [v.visit] : []));
    const fell = snow?.inches[jobId] ?? null;
    const plan = site && !site.job.paused_at ? snowPlan(rulesOf(site), fell) : null;
    // How many more visits today's snow calls for than it has.
    const more = plan ? Math.max(0, plan.pushes - visits.length) : 0;
    // A storm nobody was sent out for, and that calls for nothing now, isn't under way: it's in the season's log.
    if (!visits.length && !more) return [];
    const work: SnowPlan = more && plan ? plan : { kind: e?.kind === "salt" ? "salt" : "plow", pushes: e?.pushes ?? 1 };
    return [{ jobId, site, visits, more, fell, work, name: site ? customer(site) : e?.job.client?.display_name ?? e?.job.title ?? "", address: addressLine(site?.job.property ?? e?.job.property) || (site ?? e)?.job.title, progress: progressOf(visits, site?.clear_by ?? null, clock) }];
  });
  type Row = (typeof rows)[number];
  const toSchedule = rows.filter((r) => r.more > 0);
  const visitsToGo = toSchedule.reduce((n, r) => n + r.more, 0);
  const schedule = useMutation({
    meta: { success: (r: { created: number }) => (r.created ? `Scheduled ${r.created} ${r.created === 1 ? "visit" : "visits"} for today` : "They were scheduled already") },
    mutationFn: () => api.post<{ created: number }>("/snow/schedule", { job_ids: toSchedule.map((r) => r.jobId), day: "today" }),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: ["schedule"] });
      queryClient.invalidateQueries({ queryKey: ["snow", company.id] });
    },
  });
  const scheduleThem = async () => {
    const ok = await confirm({
      title: `Schedule ${toSchedule.length === 1 ? toSchedule[0]!.name : `${toSchedule.length} customers`} for today?`,
      body: `${visitsToGo === 1 ? "One visit" : `${visitsToGo} visits`} today, with each job's crew and people on them. They're told they're going out, and a customer set to be told hears it's coming.`,
      confirmLabel: "Schedule",
    });
    if (ok) schedule.mutate();
  };
  if (storm.isPending || !rows.length) return null;
  // What's waiting on the office first, then what's late, then what's under way; the finished last.
  const rank = (r: Row) => (!r.visits.length ? 0 : r.progress.status === "completed" ? 3 : r.progress.late ? 1 : 2);
  const ordered = [...rows].sort((a, b) => rank(a) - rank(b) || (a.site?.priority ?? 2) - (b.site?.priority ?? 2) || (a.site?.clear_by ?? "99").localeCompare(b.site?.clear_by ?? "99"));
  const out = rows.filter((r) => r.visits.length);
  return (
    <div className="card">
      <div className="card-head">
        <h2>Today</h2>
        <span className="muted small">{out.length ? `${out.filter((r) => r.progress.status === "completed").length} of ${out.length} done · ` : ""}{formatDay(`${today}T12:00:00`)}</span>
        {toSchedule.length > 0 && (
          <Button size="sm" variant="primary" icon="calendarCheck" loading={schedule.isPending} onClick={scheduleThem}>
            {toSchedule.length === 1 ? "Schedule it for today" : `Schedule ${toSchedule.length} for today`}
          </Button>
        )}
      </div>
      <table className={`table table-stack ${styles.rows}`}>
        <thead><tr><th style={{ width: "28%" }}>Customer</th><th style={{ width: "18%" }}>Work</th><th style={{ width: "11%" }}>Clear by</th><th style={{ width: "19%" }}>Crew and people</th><th style={{ width: "24%" }}>Status</th></tr></thead>
        <tbody>
          {ordered.map(({ jobId, site, visits, more, fell, work, name, address, progress }) => (
            // One that's still a snow customer opens in its popup; one that isn't any more goes to its job.
            <tr key={jobId} className={site ? "row-link" : undefined} onClick={() => site && onOpen(jobId)}>
              <td className={styles.who}>
                <Link className="cell-link" to={site ? `/snow?open=${jobId}` : `/jobs/${jobId}`} replace={Boolean(site)} onClick={(e) => e.stopPropagation()}>{name}</Link>
                <div className="muted small">{address}</div>
              </td>
              <td>
                <span className={styles.work}><Icon name={work.kind === "salt" ? "salt" : "truck"} size={16} />{workText(work)}</span>
              </td>
              <td className={site?.clear_by ? undefined : styles.blank}>
                {site?.clear_by ? <span className="tabular"><span className={styles.phoneOnly}>Clear by </span>{clockText(site.clear_by)}</span> : <span className="muted">—</span>}
              </td>
              <td>{site ? crewCell(site) : <span className="muted">—</span>}</td>
              <td className={styles.status}>
                {!visits.length ? <StatusPill label="To schedule" tone="warning" /> : progress.late ? <StatusPill label="Late" tone="danger" /> : <EntityStatus kind="visit" status={progress.status} />}
                {!visits.length ? fell != null && <div className="muted small">{inches(fell)} today, and nobody's scheduled</div>
                  : (progress.late || progress.note) && <div className="muted small">{[progress.late && (progress.status === "scheduled" ? "Not started" : statusText("visit", progress.status)), progress.note].filter(Boolean).join(" · ")}</div>}
                {visits.length > 0 && more > 0 && <div className="small" style={{ color: "var(--warning)" }}>The storm grew: {more} more to schedule</div>}
                {visits.map((v, i) => v.status === "completed" && <div key={v.id} className="small"><Link to={`/snow/report/${v.id}`} onClick={(e) => e.stopPropagation()}>{visits.length > 1 ? `Report ${i + 1}` : "Service report"}</Link></div>)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
