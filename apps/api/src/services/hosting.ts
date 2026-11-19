/**
 * Settings → Hosting and the "hosting" task: what Railway charges for this Jobly, read through
 * the owner's Railway connection (services/railway.ts), and warnings before Jobly stops.
 *
 * Railway reports this project's usage in vCPU-minutes, GB-minutes and GB sent; Jobly prices it
 * at Railway's published rates (RATES). Priced that way, a trial project's usage matched Railway's
 * own "$4.39 left" (2026-10-20). The forecast is this month so far plus the last day's rate for the
 * rest of it. The connection reaches the project, not the account's billing (that takes
 * workspace:admin, which Railway shows owners in red), so the trial's days and credit are counted
 * from when the project was made, and plans, credit, the card and the usage limit are Railway's
 * pages. Each part is optional: whatever Railway doesn't share is left out and named in `missing`.
 * Storage buckets aren't in Railway's usage figures, so each is priced from what it holds now
 * (STORAGE_PRICES.bucket a GB-month) and shown with the volumes, without a size to fill up.
 *
 * The task runs twice a day and tells the owner and admins about each warning once (the bell, plus
 * email and push by the "hosting" notification topic); the keys of those already sent are kept in
 * companies.settings.hosting_alerts. Besides what could stop Jobly or bill over the plan, it
 * says when data sent out (downloads, which Railway charges for and nothing limits) is on track for
 * an unusual month or jumps well above its usual rate (sentWarnings), and once, when photos and files
 * are on a volume at least half full on a plan with buckets, what moving them to a bucket would
 * save and what it gives up (bucketTip).
 */
import {
  ADMINS,
  RAILWAY_PLANS,
  RAILWAY_TRIAL,
  serviceLabel,
  STORAGE_PRICES,
  type HostingDisk,
  type HostingOverview,
  type HostingSent,
  type HostingService,
  type HostingWarning,
  type RailwayPlan,
  type StorageBackend,
} from "@jobly/core";
import type { Env } from "../env";
import { platformOf } from "../lib/address";
import { asJson, HttpError } from "../lib/http";
import type { Db } from "../lib/supabase";
import { bucketUsage, projectBuckets, projectDetails, projectIdOf, projectUsage, RailwayError, usageMetrics, volumeSizes, type Billed, type RailwayAccess } from "../integrations/railway";
import { railwayAccess } from "./railway";
import { keepStorageDefault } from "./storageUsage";

const DAY_MS = 24 * 60 * 60_000;
/** The week's charts: a point every three hours. */
const STEP_SECONDS = 3 * 60 * 60;
/** The screen asks again after this long; "Check again" and the task don't wait. */
const CACHE_MS = 5 * 60_000;
/** A rate from less than this much use isn't worth a forecast. */
const MIN_RATE_MS = 60 * 60_000;

/**
 * Railway's prices per unit it reports (railway.com/pricing). A 30-day month is 43,200 minutes.
 * Storage buckets aren't in what usage() reports: they're priced from what each holds now
 * (STORAGE_PRICES.bucket a GB-month) and added to the month as their own lines.
 */
export const RATES: Record<Billed, number> = {
  CPU_USAGE: 20 / 43_200, // $20 per vCPU a month
  MEMORY_USAGE_GB: 10 / 43_200, // $10 per GB of memory a month
  NETWORK_TX_GB: STORAGE_PRICES.network, // $0.05 per GB sent out
  DISK_USAGE_GB: STORAGE_PRICES.volume / 43_200, // $0.15 per GB of volume a month
  BACKUP_USAGE_GB: STORAGE_PRICES.volume / 43_200,
};

export const priced = (rows: Array<{ measurement: Billed; value: number }>) => rows.reduce((sum, r) => sum + (RATES[r.measurement] ?? 0) * r.value, 0);
/** GB sent out in `rows`. */
const sentIn = (rows: Array<{ measurement: Billed; value: number }>) => rows.reduce((sum, r) => sum + (r.measurement === "NETWORK_TX_GB" ? r.value : 0), 0);

/**
 * Data sent out worth a word, once a month: on track to send this many GB, which costs as much as
 * the whole of what Hobby includes ($5 at $0.05 a GB). A field service business sends a few GB a
 * month (pages, and the photos and plans people open); getting to 100 GB takes a lot of video, or a
 * file shared by link being downloaded over and over.
 */
export const SENT_WARN_GB = RAILWAY_PLANS.hobby.included / STORAGE_PRICES.network;
/**
 * Or a last day that sent at least SENT_JUMP_TIMES its usual daily amount this month, and at least
 * SENT_JUMP_MIN_GB ($0.10, or about $3 a month if it kept up): what a link being downloaded over and
 * over looks like as it starts, while a quiet business's ordinary busy day (0.1 GB to 0.5) says
 * nothing. The usual rate needs SENT_USUAL_DAYS of the month before the last day.
 */
export const SENT_JUMP_TIMES = 4;
export const SENT_JUMP_MIN_GB = 2;
const SENT_USUAL_DAYS = 2;
/** Photos and files on a volume this full, on a plan with buckets, hear once what a bucket would save. */
export const BUCKET_TIP_AT = 0.5;
const cents = (n: number) => Math.round(n * 100) / 100;
/** GB to the hundredth. */
const hundredths = (n: number) => Math.round(n * 100) / 100;
const money = (n: number) => `$${n.toFixed(2)}`;
const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

/** null: Railway didn't give that part (refused, or didn't answer). Anything else is a bug, and is thrown. */
async function optional<T>(work: Promise<T>): Promise<T | null> {
  try {
    return await work;
  } catch (error) {
    if (error instanceof RailwayError) return null;
    throw error;
  }
}

/** The project's buckets that are in this environment, with what each holds. */
async function bucketSizes(env: Env, access: RailwayAccess): Promise<Array<{ id: string; name: string; sizeBytes: number; objects: number }>> {
  const buckets = await projectBuckets(env, access);
  const held = await Promise.all(buckets.map(async (b) => ({ ...b, usage: await optional(bucketUsage(env, access, b.id)) })));
  return held.flatMap((b) => (b.usage ? [{ id: b.id, name: b.name, sizeBytes: b.usage.sizeBytes, objects: b.usage.objects }] : []));
}

function monthOf(now: Date) {
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
  const end = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
  return { start: start.toISOString(), end: end.toISOString() };
}

const planOf = (plan: string | null): RailwayPlan | null => {
  const name = (plan ?? "").toLowerCase();
  return name in RAILWAY_PLANS ? (name as RailwayPlan) : null;
};

const cache = new Map<string, { at: number; overview: HostingOverview }>();
export const forgetHosting = () => cache.clear();

/** GET /api/railway/usage. Without Railway access, says to connect it. */
export async function hostingOverview(env: Env, admin: Db, companyId: string, { fresh = false, now = new Date() } = {}): Promise<HostingOverview> {
  const cached = cache.get(companyId);
  if (!fresh && cached && now.getTime() - cached.at < CACHE_MS) return cached.overview;
  const access = await railwayAccess(env, admin, companyId);
  if (!access) throw new HttpError(409, "Connect Railway to see what Jobly costs.");
  const read = await readHosting(env, access, now);
  // Settings → Storage's default limit follows the plan and the storage service's volume (services/storageUsage.ts).
  const volume = read.disks.find((d) => d.kind === "volume" && d.service === "storage" && d.sizeGb);
  const storage = await keepStorageDefault(env, admin, companyId, { access, force: fresh, hint: { plan: read.plan, ...(volume ? { volumeBytes: volume.sizeGb! * 1e9 } : {}) } });
  // Where files are now, for the bucket tip.
  const overview = { ...read, warnings: hostingWarnings(read, { backend: storage?.backend ?? null }) };
  cache.set(companyId, { at: now.getTime(), overview });
  return overview;
}

/** Everything Railway shares about what this Jobly costs, and what needs doing about it. */
export async function readHosting(env: Env, access: RailwayAccess, now = new Date()): Promise<HostingOverview> {
  // The project has to answer: without it the connection itself is broken, and the error says what to do.
  const project = await projectDetails(env, access);
  const plan = planOf(project.plan);
  const period = monthOf(now);
  const created = project.createdAt ? Date.parse(project.createdAt) : Number.NaN;
  // The last day's rate, or since the project was made when that's sooner.
  const rateFrom = new Date(Math.max(now.getTime() - DAY_MS, Number.isNaN(created) ? 0 : created));
  // The trial's credit is spent from when the project was made, which may be last month.
  const trialFrom = plan === "trial" && !Number.isNaN(created) && created < Date.parse(period.start) ? new Date(created) : null;
  const [usage, recent, sinceMade, metrics, volumes, buckets] = await Promise.all([
    optional(projectUsage(env, access, new Date(period.start), now)),
    now.getTime() - rateFrom.getTime() >= MIN_RATE_MS ? optional(projectUsage(env, access, rateFrom, now)) : null,
    trialFrom ? optional(projectUsage(env, access, trialFrom, now)) : null,
    optional(usageMetrics(env, access, new Date(now.getTime() - 7 * DAY_MS), STEP_SECONDS)),
    optional(volumeSizes(env, access)),
    optional(bucketSizes(env, access)),
  ]);
  const names = new Map(project.services.map((s) => [s.id, s.name]));

  const services = new Map<string, HostingService>();
  for (const row of usage ?? []) {
    const id = row.serviceId ?? "other";
    const service = services.get(id) ?? { id, name: names.get(id) ?? "Other", cost: 0 };
    service.cost += (RATES[row.measurement] ?? 0) * row.value;
    services.set(id, service);
  }

  // Buckets cost what they hold for as long as they hold it: at today's size, a day's share of a
  // month so far and for each day left.
  const monthDays = (Date.parse(period.end) - Date.parse(period.start)) / DAY_MS;
  const bucketDisks: HostingDisk[] = (buckets ?? []).map((b) => {
    const usedGb = Math.round(b.sizeBytes / 1e7) / 100;
    return { service: b.name, kind: "bucket", usedGb, sizeGb: null, objects: b.objects, monthly: cents((b.sizeBytes / 1e9) * STORAGE_PRICES.bucket) };
  });
  const daysSoFar = (now.getTime() - Date.parse(period.start)) / DAY_MS;
  let bucketDaily = 0;
  for (const b of buckets ?? []) {
    const daily = ((b.sizeBytes / 1e9) * STORAGE_PRICES.bucket) / monthDays;
    bucketDaily += daily;
    if (usage && daily > 0) services.set(b.id, { id: b.id, name: b.name, cost: daily * daysSoFar });
  }

  const points = new Map<number, { memory: number; cpu: number }>();
  for (const series of metrics ?? []) {
    // A series without a service (one that's gone) is all zeros.
    if (!series.serviceId) continue;
    for (const { ts, value } of series.values) {
      const at = Math.round(ts / STEP_SECONDS) * STEP_SECONDS;
      const point = points.get(at) ?? { memory: 0, cpu: 0 };
      if (series.measurement === "MEMORY_USAGE_GB") point.memory += value;
      else point.cpu += value;
      points.set(at, point);
    }
  }

  // Data sent out: this month, the last day, and the month's usual day before that (from when the
  // project was made, if that's this month).
  const counted = (now.getTime() - Math.max(Date.parse(period.start), Number.isNaN(created) ? 0 : created)) / DAY_MS;
  const recentDays = (now.getTime() - rateFrom.getTime()) / DAY_MS;
  const sentSoFar = usage ? sentIn(usage) : 0;
  const sentPerDay = recent ? sentIn(recent) / recentDays : null;
  const usualDays = counted - recentDays;
  const sent: HostingSent | null = usage
    ? {
        soFar: hundredths(sentSoFar),
        perDay: sentPerDay === null ? null : hundredths(sentPerDay),
        usualPerDay: recent && usualDays >= SENT_USUAL_DAYS ? hundredths(Math.max(0, sentSoFar - sentIn(recent)) / usualDays) : null,
        forecast: sentPerDay === null ? null : hundredths(sentSoFar + sentPerDay * ((Date.parse(period.end) - now.getTime()) / DAY_MS)),
      }
    : null;

  const cost = usage ? priced(usage) + bucketDaily * daysSoFar : 0;
  const perDay = recent ? priced(recent) / ((now.getTime() - rateFrom.getTime()) / DAY_MS) + bucketDaily : null;
  const forecast = usage && perDay !== null ? cost + perDay * ((Date.parse(period.end) - now.getTime()) / DAY_MS) : null;
  const spentOnTrial = trialFrom ? (sinceMade ? priced(sinceMade) : null) : usage ? cost : null;
  const overview: Omit<HostingOverview, "warnings"> = {
    projectName: project.name,
    plan,
    period,
    project: usage
      ? {
          cost: cents(cost),
          perDay: perDay === null ? null : cents(perDay),
          forecast: forecast === null ? null : cents(forecast),
          services: [...services.values()].map((s) => ({ ...s, cost: cents(s.cost) })).filter((s) => s.cost > 0).sort((a, b) => b.cost - a.cost),
        }
      : null,
    sent,
    trial:
      plan === "trial" && !Number.isNaN(created) && spentOnTrial !== null
        ? { daysLeft: Math.max(0, Math.ceil(RAILWAY_TRIAL.days - (now.getTime() - created) / DAY_MS)), creditLeft: cents(Math.max(0, RAILWAY_TRIAL.credit - spentOnTrial)) }
        : null,
    disks: [
      ...(volumes ?? []).map((v): HostingDisk => ({ service: names.get(v.serviceId ?? "") ?? "Volume", kind: "volume", usedGb: Math.round(v.usedMb / 10) / 100, sizeGb: Math.round(v.sizeMb / 10) / 100 })),
      ...bucketDisks,
    ],
    week: [...points.entries()].sort(([a], [b]) => a - b).map(([at, p]) => ({ at: new Date(at * 1000).toISOString(), memory: Math.round(p.memory * 1000) / 1000, cpu: Math.round(p.cpu * 1000) / 1000 })),
    missing: [...(usage ? [] : ["usage" as const]), ...(metrics ? [] : ["charts" as const])],
    links: {
      usage: "https://railway.com/workspace/usage",
      billing: "https://railway.com/workspace/billing",
      upgrade: "https://railway.com/workspace/upgrade",
      plans: "https://railway.com/workspace/plans",
      project: `https://railway.com/project/${projectIdOf(env)}`,
    },
    checkedAt: now.toISOString(),
  };
  return { ...overview, warnings: hostingWarnings(overview) };
}

const RANK: Record<HostingWarning["level"], number> = { urgent: 0, warning: 1, tip: 2 };

/**
 * What needs doing before Railway stops Jobly or bills more than the plan includes, most urgent
 * first, then a way to pay less. `backend`: where photos and files are now, when it's known (the
 * bucket tip needs it).
 */
export function hostingWarnings(o: Omit<HostingOverview, "warnings">, { backend = null }: { backend?: StorageBackend | null } = {}): HostingWarning[] {
  const warnings: HostingWarning[] = [];
  const period = o.period.start.slice(0, 7);
  const { plan, trial } = o;
  const perDay = o.project?.perDay ?? null;

  if (trial) {
    const left = trial.daysLeft;
    if (left <= 7) {
      const step = left <= 1 ? 1 : left <= 3 ? 3 : 7;
      warnings.push({
        key: `trial-${step}`,
        level: left <= 3 ? "urgent" : "warning",
        title: left <= 0 ? "Your Railway trial ends today" : `Your Railway trial ends in about ${plural(left, "day")}`,
        body: "Jobly stops when it does. To keep it running, choose Railway's Hobby plan: $5 a month, including $5 of usage.",
        action: "upgrade",
      });
    }
    const days = perDay ? Math.floor(trial.creditLeft / perDay) : null;
    if (trial.creditLeft <= 1 || (days !== null && days <= 3 && days < left)) {
      warnings.push({
        key: "trial-credit",
        level: "urgent",
        title: "Your Railway trial credit is almost used up",
        body: `About ${money(trial.creditLeft)} of the $5 is left${days !== null ? `, about ${plural(days, "day")} at this rate` : ""}. Jobly stops when it runs out, so choose Railway's Hobby plan before then.`,
        action: "upgrade",
      });
    }
  }

  if (plan === "free") {
    warnings.push({ key: "free", level: "warning", title: "Jobly is on Railway's Free plan", body: "Free includes $1 of usage a month, less than Jobly needs, so Railway stops it partway through the month. Choose the Hobby plan ($5 a month, including $5 of usage) to keep it running.", action: "upgrade" });
  }

  const forecast = o.project?.forecast ?? null;
  if ((plan === "hobby" || plan === "pro") && forecast !== null) {
    const { name, price, included } = RAILWAY_PLANS[plan];
    const over = forecast - included;
    if (over >= 0.5) {
      warnings.push({
        key: `over:${period}`,
        level: "warning",
        title: `About ${money(forecast)} of Railway usage this month`,
        body: `That's ${money(over)} more than the ${money(included)} ${name} includes, so Railway adds about ${money(over)} to the ${money(price)} plan. Settings → Hosting in Jobly shows what's using it.`,
        action: null,
      });
    }
  }

  for (const disk of o.disks) {
    // A bucket grows as it fills, so it's never full.
    if (disk.kind === "bucket" || !disk.sizeGb) continue;
    const full = disk.usedGb / disk.sizeGb;
    if (full < 0.85) continue;
    const label = serviceLabel(disk.service);
    warnings.push({
      key: `disk:${disk.service}:${full >= 0.95 ? 95 : 85}`,
      level: full >= 0.95 ? "urgent" : "warning",
      title: `${label} storage is ${Math.floor(full * 100)}% full`,
      body: `${disk.usedGb} of ${disk.sizeGb} GB is used. When it's full, Jobly can't save anything new there. Make the volume on the ${disk.service} service bigger in Railway; Hobby volumes go up to 5 GB, and Pro goes much higher.${
        disk.service === "storage" ? " Or move photos and files to a Railway bucket, which grows as it fills, from Settings → Hosting." : ""
      }`,
      action: "project",
    });
  }

  warnings.push(...sentWarnings(o));
  const tip = bucketTip(o, backend);
  if (tip) warnings.push(tip);

  return warnings.sort((a, b) => RANK[a.level] - RANK[b.level]);
}

const gbText = (n: number) => `${n < 10 ? Number(n.toFixed(1)) : Math.round(n)} GB`;

/** Data sent out on track for an unusual month, or a day well above the usual: once a month each. */
export function sentWarnings(o: Pick<HostingOverview, "period" | "sent">): HostingWarning[] {
  const sent = o.sent;
  if (!sent) return [];
  const period = o.period.start.slice(0, 7);
  const price = STORAGE_PRICES.network;
  const shared = "Opening photos, plan sets and videos sends data, and so do the pictures on guides and showcases shared by link.";
  const warnings: HostingWarning[] = [];
  if (sent.forecast !== null && sent.forecast >= SENT_WARN_GB) {
    warnings.push({
      key: `sent:${period}`,
      level: "warning",
      title: `Jobly is on track to send about ${gbText(sent.forecast)} this month`,
      body: `That's about ${money(sent.forecast * price)} of Railway usage, at ${money(price)} for each GB sent to people's phones and browsers. ${shared} If that's more than your team and clients use, check what's shared by link.`,
      action: null,
    });
  }
  const { perDay, usualPerDay } = sent;
  if (perDay !== null && usualPerDay !== null && perDay >= SENT_JUMP_MIN_GB && perDay >= SENT_JUMP_TIMES * Math.max(usualPerDay, 0.01)) {
    const times = usualPerDay > 0 ? Math.floor(perDay / usualPerDay) : null;
    warnings.push({
      key: `sent-jump:${period}`,
      level: "warning",
      title: "Jobly sent far more data than usual in the last day",
      body: `About ${gbText(perDay)} in the last day${times ? `, ${times} times its usual ${gbText(usualPerDay)} a day this month` : ""}. Railway charges ${money(price)} for each GB, so at that rate it's about ${money(perDay * price * 30)} a month. ${shared} If nobody expected that, check what's shared by link.`,
      action: null,
    });
  }
  return warnings;
}

/**
 * Once, while photos and files are on the storage service's volume at least half full, on a plan
 * with buckets (Hobby and Pro: the trial's bucket goes when the trial does, and Free's when its $1
 * runs out): what a bucket would save, and what it gives up.
 */
export function bucketTip(o: Pick<HostingOverview, "plan" | "disks">, backend: StorageBackend | null): HostingWarning | null {
  if (backend !== "volume" || (o.plan !== "hobby" && o.plan !== "pro")) return null;
  const volume = o.disks.find((d) => d.kind === "volume" && d.service === "storage" && d.sizeGb);
  if (!volume?.sizeGb || volume.usedGb / volume.sizeGb < BUCKET_TIP_AT) return null;
  const now = volume.usedGb * STORAGE_PRICES.volume;
  const there = volume.usedGb * STORAGE_PRICES.bucket;
  return {
    key: "bucket",
    level: "tip",
    title: "Photos and files would cost a tenth as much in a Railway bucket",
    body: `They take ${gbText(volume.usedGb)}, ${Math.floor((volume.usedGb / volume.sizeGb) * 100)}% of the ${gbText(volume.sizeGb)} volume, which costs about ${money(now)} a month; in a bucket it's about ${money(there)}, and a bucket has no size to outgrow. But Railway backs up volumes on its Pro plan, and never buckets. Settings → Hosting → Files storage moves them with one press, and can move them back.`,
    action: "files",
  };
}

/** Railway stopped accepting Jobly's sign-in: nothing else can be checked until the owner logs in again. */
const LAPSED: HostingWarning = {
  key: "lapsed",
  level: "urgent",
  title: "Jobly lost its Railway connection",
  body: "Log in with Railway again in Settings → Hosting, so Jobly can warn you before your Railway trial runs out or the bill goes over your plan.",
  action: null,
};

/** Sent warnings are forgotten after this long, so one that comes back later is sent again. */
const REMEMBER_MS = 90 * DAY_MS;
/** Said once and never again: the bucket tip is advice, not a problem that comes back. */
const ONCE = new Set(["bucket"]);

/** The "hosting" task, twice a day: tells the owner and admins about each new warning, once. */
export async function checkHosting(env: Env, admin: Db, now = new Date()): Promise<Record<string, unknown>> {
  if (env.JOBLY_SINGLE_COMPANY !== "1" || platformOf(env) !== "railway") return { skipped: "not on Railway" };
  const { data: companies, error } = await admin.from("companies").select("id, settings");
  if (error) throw new Error(error.message);
  let sent = 0;
  let unreadable = 0;
  for (const company of companies ?? []) {
    let warnings: HostingWarning[] = [];
    let connected = false;
    const access = await railwayAccess(env, admin, company.id).catch(() => null);
    if (access) {
      const overview = await hostingOverview(env, admin, company.id, { fresh: true, now }).catch((e: unknown) => {
        console.warn("Couldn't read Railway usage", e instanceof Error ? e.message : e);
        return null;
      });
      if (!overview) unreadable++;
      warnings = overview?.warnings ?? [];
      connected = Boolean(overview);
    } else {
      // Never connected: the owner is asked at sign-in. Connected once and then refused: say so.
      const { data: row } = await admin.from("integrations").select("status").match({ company_id: company.id, provider: "railway" }).maybeSingle();
      if (row?.status === "error") warnings = [LAPSED];
    }
    const before = ((company.settings as { hosting_alerts?: Record<string, string> } | null)?.hosting_alerts ?? {}) as Record<string, string>;
    const fresh = warnings.filter((w) => !before[w.key]);
    if (fresh.length) sent += await tellAdmins(admin, company.id, fresh);
    const kept = Object.fromEntries(
      Object.entries(before).filter(([key, at]) => (ONCE.has(key) || now.getTime() - Date.parse(at) < REMEMBER_MS) && !(connected && key === LAPSED.key)),
    );
    const after = { ...kept, ...Object.fromEntries(fresh.map((w) => [w.key, now.toISOString()])) };
    if (JSON.stringify(after) !== JSON.stringify(before)) await rememberAlerts(admin, company.id, after);
  }
  return { companies: companies?.length ?? 0, sent, unreadable };
}

async function tellAdmins(admin: Db, companyId: string, warnings: HostingWarning[]): Promise<number> {
  const { data: people } = await admin.from("memberships").select("user_id").eq("company_id", companyId).eq("active", true).in("role", [...ADMINS]);
  if (!people?.length) return 0;
  const rows = people.flatMap((p) => warnings.map((w) => ({ company_id: companyId, user_id: p.user_id, kind: "hosting", title: w.title, body: w.body, link: "/settings?tab=hosting" })));
  const { error } = await admin.from("notifications").insert(rows);
  if (error) throw new Error(error.message);
  return warnings.length;
}

/** Read fresh, so a setting changed meanwhile isn't undone. */
async function rememberAlerts(admin: Db, companyId: string, alerts: Record<string, string>) {
  const { data } = await admin.from("companies").select("settings").eq("id", companyId).maybeSingle();
  const settings = (data?.settings ?? {}) as Record<string, unknown>;
  const { error } = await admin.from("companies").update({ settings: asJson({ ...settings, hosting_alerts: alerts }) }).eq("id", companyId);
  if (error) throw new Error(error.message);
}
