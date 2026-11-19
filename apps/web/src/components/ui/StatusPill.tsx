/*
 * Status words: the one place they're written. Each kind of record, its states, and the label each
 * state gets everywhere (two words at most). Anything else that names a state, a filter, a column, a
 * stat, a picker, uses statusText or these same words, so a state never reads two ways.
 *
 *   Client   lead "Lead" · active "Active" · archived "Archived"
 *   Request  new "New" · assessment_scheduled "Assessment booked" · assessment_complete "Assessment done" ·
 *            quoted "Quoted" · converted "Converted" · archived "Archived"
 *   Quote    draft "Draft" · sent "Awaiting response" · changes_requested "Changes requested" ·
 *            approved "Approved" · converted "Converted" · lost "Lost" · archived "Archived"
 *   Job      active "Active" · requires_invoicing "Requires invoicing" · completed "Completed" · archived "Archived"
 *            (an active job shows its state from its visits instead, public.job_state: late "Late" ·
 *            today "Today" · upcoming "Upcoming" · unscheduled "Unscheduled", or paused "Paused")
 *   Invoice  draft "Draft" · sent "Awaiting payment" · partially_paid "Partly paid" · paid "Paid" ·
 *            overdue "Past due" · void "Void" · written_off "Written off"
 *   Visit    unscheduled "Unscheduled" · scheduled "Scheduled" · en_route "On the way" ·
 *            in_progress "In progress" · completed "Completed" · cancelled "Cancelled"
 *   Referral new "New lead" · quoted "Quoted" · won "Won" · lost "Lost"
 *   Credit   pending "Pending" · earned "Earned" · applied "Applied" · issued "Given" · none "No credit"
 *            (a referral credit: Marketing → Referrals shows the referral's state until the friend
 *            pays, then its credit's, and No credit for a friend who was the referrer or already a
 *            client, who isn't a lead: packages/core/src/marketing.ts referralPill)
 *   Campaign draft "Draft" · scheduled "Scheduled" · sending "Sending" · sent "Sent" · cancelled "Stopped" ·
 *            automated "Automated" (one that sends by itself, Marketing → Campaigns)
 *   Recipient pending "Queued" · sending "Sending" · sent "Sent" · failed "Failed" · skipped "Skipped" ·
 *            opened "Opened" · clicked "Clicked" (a campaign email, and what was done with it)
 *   Review   needs_reply "Needs a reply" · replied "Replied" (a Google review, Marketing → Reviews)
 *   Post     draft "Draft" · scheduled "Scheduled" · posting "Posting" · posted "Posted" ·
 *            partly_posted "Partly posted" · check "Unconfirmed" · failed "Failed" · cancelled "Cancelled"
 *            (a social post, Marketing → Social)
 *   Network  waiting "Queued" · sending "Posting" · posted "Posted" · retry "Trying again" · failed "Failed" ·
 *            unknown "Unconfirmed" · skipped "Skipped" (where a social post goes, and how it went there)
 *
 * Money that's late is "Past due", never "Overdue" or "Waiting on payment". "Overdue" is kept for work
 * that's late: a new request nobody has answered in two days (Home's workflow), a visit past its day
 * (its job is "Late", the word Jobber uses), equipment maintenance. packages/core/src/automations.ts
 * (STATUS_CHOICES) repeats these words for the automation builder, so change both together. A paving or roofing project's stage ("Proposal sent",
 * "Won") is its own thing, worded in features/paving/data.ts and features/roofing/data.ts.
 */
import { msg, t } from "@/lib/i18n";

const TONES = {
  good: { bg: "var(--green-tint)", fg: "var(--green-dark)", dot: "var(--job)" },
  info: { bg: "var(--invoice-tint)", fg: "var(--invoice-text)", dot: "var(--invoice)" },
  warning: { bg: "var(--warning-tint)", fg: "var(--warning)", dot: "var(--req)" },
  danger: { bg: "var(--danger-tint)", fg: "var(--danger)", dot: "var(--danger)" },
  muted: { bg: "var(--fill-2)", fg: "var(--text-2)", dot: "#9aa39d" },
} as const;

export type Tone = keyof typeof TONES;

/**
 * Status is always shown as text, never color alone. A state that needs someone (warning, danger)
 * is a tinted pill; a steady one is its dot and plain words, so the ones to act on stand out in a list.
 */
export function StatusPill({ label, tone = "muted" }: { label: string; tone?: Tone }) {
  const colors = TONES[tone];
  const quiet = tone !== "warning" && tone !== "danger";
  return (
    <span className={quiet ? "pill pill-quiet" : "pill"} style={quiet ? undefined : { background: colors.bg, color: colors.fg }}>
      <span className="pill-dot" style={{ background: colors.dot }} />
      {label}
    </span>
  );
}

/** "in_progress" -> "In progress". For other snake_case words; a record's status goes through statusText. */
export const statusLabel = (status: string) => (status.charAt(0).toUpperCase() + status.slice(1)).replace(/_/g, " ");

/**
 * The kinds a team member meets on their own screens are marked for translation, each with its kind
 * as the context (a visit is "Terminada", a job "Terminado"); the office's own kinds stay English.
 */
const STATUS_TEXT = {
  client: { lead: msg("Lead", "client"), active: msg("Active", "client"), archived: msg("Archived", "client") },
  request: { new: msg("New", "request"), assessment_scheduled: msg("Assessment booked", "request"), assessment_complete: msg("Assessment done", "request"), quoted: msg("Quoted", "request"), converted: msg("Converted", "request"), archived: msg("Archived", "request") },
  quote: { draft: msg("Draft", "quote"), sent: msg("Awaiting response", "quote"), changes_requested: msg("Changes requested", "quote"), approved: msg("Approved", "quote"), converted: msg("Converted", "quote"), lost: msg("Lost", "quote"), archived: msg("Archived", "quote") },
  job: { active: msg("Active", "job"), requires_invoicing: msg("Requires invoicing", "job"), completed: msg("Completed", "job"), archived: msg("Archived", "job"), late: msg("Late", "job"), today: msg("Today", "job"), upcoming: msg("Upcoming", "job"), unscheduled: msg("Unscheduled", "job"), paused: msg("Paused", "job") },
  invoice: { draft: msg("Draft", "invoice"), sent: msg("Awaiting payment", "invoice"), partially_paid: msg("Partly paid", "invoice"), paid: msg("Paid", "invoice"), overdue: msg("Past due", "invoice"), void: msg("Void", "invoice"), written_off: msg("Written off", "invoice") },
  visit: { unscheduled: msg("Unscheduled", "visit"), scheduled: msg("Scheduled", "visit"), en_route: msg("On the way", "visit"), in_progress: msg("In progress", "visit"), completed: msg("Completed", "visit"), cancelled: msg("Cancelled", "visit") },
  // The office's lists (referrals, campaigns, reviews, posts) are still in English, as their screens are.
  // i18n-ignore
  referral: { new: "New lead", quoted: "Quoted", won: "Won", lost: "Lost" },
  credit: { pending: "Pending", earned: "Earned", applied: "Applied", issued: "Given", none: "No credit" }, // i18n-ignore
  campaign: { draft: "Draft", scheduled: "Scheduled", sending: "Sending", sent: "Sent", cancelled: "Stopped", automated: "Automated" },
  recipient: { pending: "Queued", sending: "Sending", sent: "Sent", failed: "Failed", skipped: "Skipped", opened: "Opened", clicked: "Clicked" },
  // i18n-ignore
  review: { needs_reply: "Needs a reply", replied: "Replied" },
  post: { draft: "Draft", scheduled: "Scheduled", posting: "Posting", posted: "Posted", partly_posted: "Partly posted", check: "Unconfirmed", failed: "Failed", cancelled: "Cancelled" }, // i18n-ignore
  network: { waiting: "Queued", sending: "Posting", posted: "Posted", retry: "Trying again", failed: "Failed", unknown: "Unconfirmed", skipped: "Skipped" }, // i18n-ignore
} satisfies Record<string, Record<string, string>>;

export type StatusKind = keyof typeof STATUS_TEXT;

/** The label for a record's state, from the list at the top: statusText("invoice", "overdue") is "Past due". */
export const statusText = (kind: StatusKind, status: string) => t((STATUS_TEXT[kind] as Record<string, string>)[status] ?? statusLabel(status));

/** What a visit that isn't plain work is: "Assessment", "Task", "Event". */
const VISIT_KINDS: Record<string, string> = { job: msg("Job"), assessment: msg("Assessment"), task: msg("Task"), event: msg("Event") };
export const visitKindText = (kind: string) => t(VISIT_KINDS[kind] ?? statusLabel(kind));

const VISIT_TONES: Record<string, Tone> = {
  completed: "good",
  in_progress: "info",
  en_route: "info",
  scheduled: "muted",
  unscheduled: "warning",
  cancelled: "danger",
};

export const visitTone = (status: string): Tone => VISIT_TONES[status] ?? "muted";

const ENTITY_TONES: Record<StatusKind, Record<string, Tone>> = {
  client: { lead: "warning", active: "good", archived: "muted" },
  request: { new: "warning", assessment_scheduled: "info", assessment_complete: "info", quoted: "good", converted: "good", archived: "muted" },
  quote: { draft: "muted", sent: "info", changes_requested: "warning", approved: "good", converted: "good", lost: "danger", archived: "muted" },
  // An active job's states read like its visits': late in red, today under way, upcoming waiting, unscheduled to see to, paused at rest.
  job: { active: "info", requires_invoicing: "warning", completed: "good", archived: "muted", late: "danger", today: "info", upcoming: "muted", unscheduled: "warning", paused: "muted" },
  invoice: { draft: "muted", sent: "info", partially_paid: "warning", paid: "good", overdue: "danger", void: "muted", written_off: "muted" },
  visit: VISIT_TONES,
  referral: { new: "warning", quoted: "info", won: "good", lost: "danger" },
  credit: { pending: "muted", earned: "warning", applied: "good", issued: "good", none: "muted" },
  campaign: { draft: "muted", scheduled: "info", sending: "info", sent: "good", cancelled: "danger", automated: "info" },
  // Each step further reads stronger: sent, then opened, then clicked.
  recipient: { pending: "muted", sending: "info", sent: "muted", failed: "danger", skipped: "muted", opened: "info", clicked: "good" },
  review: { needs_reply: "warning", replied: "good" },
  post: { draft: "muted", scheduled: "info", posting: "info", posted: "good", partly_posted: "warning", check: "warning", failed: "danger", cancelled: "muted" },
  network: { waiting: "muted", sending: "info", posted: "good", retry: "warning", failed: "danger", unknown: "warning", skipped: "muted" },
};

/** Pill for a record's status, e.g. <EntityStatus kind="quote" status="sent" />. */
export function EntityStatus({ kind, status }: { kind: StatusKind; status: string }) {
  return <StatusPill label={statusText(kind, status)} tone={ENTITY_TONES[kind][status] ?? "muted"} />;
}
