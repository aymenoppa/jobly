/**
 * The one-time notice of what Jobly collects about where a worker is, and whether this phone
 * may read its position yet. Two things are said, each acknowledged once per person and company
 * (worker_notices, with the date: supabase/migrations/20261113001810_location_notice.sql):
 *
 *   clock_location      Where they are is saved when they clock in and out (the company keeps
 *                       that unless it turned it off: Settings → Company → Time clock).
 *   clock_at_property   With the clock at the property on, the phone compares its position with
 *                       the property while Jobly is open, without saving it.
 *
 * Until the notice is acknowledged the phone's position isn't read for either: a clock tap goes
 * through with no place (`NOT_YET`), and the clock at the property stays off. Nobody's clock ever
 * waits on it. What was acknowledged is kept on the phone, so it holds with no signal, and sent to
 * the server when there is some; a phone they haven't used before learns it from the server.
 */
import { geofence } from "@jobly/core/geofence";
import { keepsTime, type Company, type Session } from "@/lib/session";

export type NoticeKind = "clock_location" | "clock_at_property";
type Who = Pick<Session, "userId" | "role" | "subcontractor"> & { company: Pick<Company, "id" | "settings"> };

/** What a clock tap carries for its place while the notice hasn't been acknowledged: no position was read. */
export const NOT_YET = { missing: "unavailable" } as const;

const PREFIX = "jobly-location-notice:";
/** For a phone that won't keep it (storage full or turned off): what this page knows. */
const memory = new Map<string, string>();
const listeners = new Set<() => void>();
let version = 0;

const keyOf = (companyId: string, userId: string, notice: NoticeKind) => `${PREFIX}${companyId}:${userId}:${notice}`;
function read(key: string): string | null {
  try {
    return localStorage.getItem(key) ?? memory.get(key) ?? null;
  } catch {
    return memory.get(key) ?? null;
  }
}
function write(key: string, value: string) {
  memory.set(key, value);
  try {
    localStorage.setItem(key, value);
  } catch {
    // Remembered for as long as the page is open, then asked again.
  }
  version += 1;
  listeners.forEach((listener) => listener());
}

/** For React: re-render when something is acknowledged. */
export const subscribeNotices = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
export const noticesVersion = () => version;

/** Whether the company keeps where people clock in and out. On unless switched off. */
const savesPlaces = (company: Pick<Company, "settings">) => (company.settings?.clock as { record_location?: boolean } | undefined)?.record_location !== false;

/** The notices that apply to this person at this company: none for someone whose hours aren't kept here. */
export function noticesFor(session: Who): NoticeKind[] {
  if (!keepsTime(session)) return [];
  return [...(savesPlaces(session.company) ? (["clock_location"] as const) : []), ...(geofence(session.company.settings).mode !== "off" ? (["clock_at_property"] as const) : [])];
}

/** When this person acknowledged a notice, as this phone knows it, or null. */
export const acknowledgedAt = (session: Who, notice: NoticeKind) => read(keyOf(session.company.id, session.userId, notice));

/** The notices this person still has to be shown. */
export const noticesToShow = (session: Who) => noticesFor(session).filter((notice) => acknowledgedAt(session, notice) === null);

/**
 * Whether this phone may read its position for something yet. True where no notice applies (a sub
 * the office keeps no hours for, whose On my way only works out when they'll arrive).
 */
export const mayUsePlace = (session: Who, notice: NoticeKind) => !noticesFor(session).includes(notice) || acknowledgedAt(session, notice) !== null;

/** Acknowledged now, on this phone. Gives what to send to the server. */
export function acknowledgeHere(session: Who, notices: readonly NoticeKind[], at = new Date().toISOString()): { notices: NoticeKind[]; at: string } {
  for (const notice of notices) write(keyOf(session.company.id, session.userId, notice), at);
  return { notices: [...notices], at };
}

/** What the server has on record, for a phone that didn't know: kept here with the server's dates. */
export function learnAcknowledged(session: Who, rows: ReadonlyArray<{ notice: string; acknowledged_at: string }>) {
  for (const row of rows) {
    if (row.notice !== "clock_location" && row.notice !== "clock_at_property") continue;
    const key = keyOf(session.company.id, session.userId, row.notice);
    if (read(key) === null) write(key, row.acknowledged_at);
    markSent(session, row.notice);
  }
}

const sentKey = (session: Who, notice: NoticeKind) => `${keyOf(session.company.id, session.userId, notice)}:sent`;
/** The server has this one. */
export function markSent(session: Who, notice: NoticeKind) {
  memory.set(sentKey(session, notice), "1");
  try {
    localStorage.setItem(sentKey(session, notice), "1");
  } catch {
    // Sent again next time, which changes nothing: the first date stands.
  }
}
/** Acknowledged on this phone and not yet on the server (there was no signal), with the earliest date among them. */
export function unsentNotices(session: Who): { notices: NoticeKind[]; at: string } | null {
  const waiting = noticesFor(session).filter((notice) => acknowledgedAt(session, notice) !== null && read(sentKey(session, notice)) === null);
  if (!waiting.length) return null;
  return { notices: waiting, at: waiting.map((notice) => acknowledgedAt(session, notice)!).sort()[0]! };
}

/** For the tests: a phone that knows nothing. */
export function forgetNotices() {
  memory.clear();
  version += 1;
}
