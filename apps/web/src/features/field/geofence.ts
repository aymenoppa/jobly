/**
 * The clock at the property, on the phone (Settings → Company → Time clock → At the property).
 * packages/core/src/geofence.ts decides everything; this part finds where the phone is, keeps what
 * the geofence knows between looks, and carries out what it decides:
 *
 *   - Only while My day or a visit's screen is open, for someone whose hours the company keeps,
 *     while they have a visit today with a point on the map that isn't finished. A web page can't
 *     watch the position in the background: phones pause it, and it catches up when it's opened.
 *   - It looks every half minute or so near a property, less often and less precisely far away.
 *   - The position stays on the phone. A clock the geofence starts, or moves to driving as they
 *     leave (the whole-day clock only: it never takes anyone off the clock), goes through the same
 *     offline-safe tap as the clock card's (clockTaps.ts, fieldActions.setClock), marked as the
 *     geofence's, and carries where the phone was only when the company keeps that.
 *   - What it asks ("You're at 12 Oak St. Start the visit?") waits on the screen (GeofenceCard),
 *     with a buzz, and as a phone notification for someone who allowed Jobly's notifications.
 *   - A clock tap the person makes on a visit while there (the clock card, the crew clock) takes
 *     that visit's clock off the geofence until they leave and come back (core noteTap).
 *   - Not until the person has acknowledged the notice of what this does with their position
 *     (locationNotice.ts): before that the phone isn't asked where it is at all.
 *
 * What it knows is kept on the phone per person and day (localStorage), so a page reloaded at the
 * property doesn't take it for a new arrival. A phone that won't keep it (storage full or turned
 * off) still works from what this page remembers. What it's asking is kept the same way, so a
 * question is still there after the page loads again (tapping its notification can do that).
 */
import {
  emptyGeofence,
  geofence as geofenceSetting,
  geofenceStep,
  keepSites,
  nextLook,
  noteTap,
  type Fix,
  type GeofenceAction,
  type GeofenceSite,
  type GeofenceState,
} from "@jobly/core/geofence";
import { onlineManager, useMutation, useQueryClient, type QueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { mayUsePlace, NOT_YET, noticesVersion, subscribeNotices } from "./locationNotice";
import { todayIn } from "@/lib/format";
import { FIELD_SCOPE } from "@/lib/offline";
import { keepsTime, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { clockChange, showClockTap, type ClockChange, type ClockTarget, type ShownClock } from "./clockTaps";
import { onDayClock, recordsPlaces, useRunningTimer, type ClockPlace } from "./fieldData";
import { dayOrder, useMyDay, type MyDayVisit } from "./myDay";
import { t } from "@/lib/i18n";

// ---------------------------------------------------------------------------------------------
// What the geofence asks, waiting on the screen
// ---------------------------------------------------------------------------------------------

export interface GeofencePrompt {
  /** One question at a time per visit and kind. */
  id: string;
  kind: "start" | "finish";
  visitId: string;
  jobId: string | null;
  title: string;
  /** The street line: "12 Oak St". */
  place: string;
  /** Start: the visit is under way already, so only their clock is offered. */
  clockOnly?: boolean;
  /** Finish: the visit is in progress, so Complete visit is offered. */
  complete?: boolean;
  /** Finish: their clock is still on the visit, so stopping it is offered. */
  stopClock?: boolean;
  /** What the phone did already: "Clock started at 12 Oak St". */
  done?: string;
}

let prompts: readonly GeofencePrompt[] = [];
/** Where the questions are kept on the phone (per person and day, as what the geofence knows is). */
let promptsKey: string | null = null;
const listeners = new Set<() => void>();
const ASKS = "jobly-geofence-asks:";
const setPrompts = (next: readonly GeofencePrompt[]) => {
  prompts = next;
  // Kept on the phone as well: the page can load again with a question still unanswered (a tap on
  // its notification reloads it), and the arrival behind it has been used up by then.
  if (promptsKey) {
    try {
      if (next.length) localStorage.setItem(promptsKey, JSON.stringify(next));
      else localStorage.removeItem(promptsKey);
    } catch {
      // On the screen only, then.
    }
  }
  listeners.forEach((listener) => listener());
};
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => void listeners.delete(listener);
};
export const useGeofencePrompts = () => useSyncExternalStore(subscribe, () => prompts);
export const geofencePrompts = () => prompts;
export const dismissPrompt = (id: string) => {
  if (prompts.some((p) => p.id === id)) setPrompts(prompts.filter((p) => p.id !== id));
};
/** A new question replaces one about the same visit (arriving again, then leaving). */
export const askPrompt = (prompt: GeofencePrompt) => setPrompts([...prompts.filter((p) => p.visitId !== prompt.visitId), prompt]);

const isPrompt = (p: unknown): p is GeofencePrompt =>
  Boolean(p) && typeof p === "object" && typeof (p as GeofencePrompt).id === "string" && typeof (p as GeofencePrompt).visitId === "string" && ((p as GeofencePrompt).kind === "start" || (p as GeofencePrompt).kind === "finish");

/**
 * The questions for this person and day (`key`: geofenceKey), as the phone kept them: called as
 * the geofence starts on a screen. Questions this page is already showing for them stay; another
 * person's, or another day's, are dropped.
 */
export function restorePrompts(key: string) {
  const mine = `${ASKS}${key.slice(PREFIX.length)}`;
  if (promptsKey === mine) return;
  promptsKey = mine;
  let saved: GeofencePrompt[] = [];
  try {
    const read = JSON.parse(localStorage.getItem(mine) ?? "[]") as unknown;
    if (Array.isArray(read)) saved = read.filter(isPrompt);
    // Other days' questions are done with.
    const person = mine.slice(0, mine.lastIndexOf(":") + 1);
    for (let i = localStorage.length - 1; i >= 0; i--) {
      const k = localStorage.key(i);
      if (k && k.startsWith(person) && k !== mine) localStorage.removeItem(k);
    }
  } catch {
    // Storage turned off, or something unreadable: nothing kept.
  }
  prompts = saved;
  listeners.forEach((listener) => listener());
}

/** The question as one line, for the card and the phone's notification. */
export function promptText(p: GeofencePrompt): { title: string; question: string } {
  if (p.kind === "start") return { title: t("You're at {place}", { place: p.place }), question: p.clockOnly ? t("Start your clock?") : t("Start the visit?") };
  const question = p.complete && p.stopClock ? t("Complete the visit, or stop your clock?") : p.complete ? t("Complete the visit?") : t("Stop your clock?");
  return { title: t("Leaving {place}", { place: p.place }), question };
}

/** Whether a question still means anything, now the visit and the clock are as they are. */
export function promptStands(p: GeofencePrompt, status: string | undefined, clock: Pick<ShownClock, "visit"> | null | undefined): boolean {
  if (!status || status === "completed" || status === "cancelled") return false;
  const onIt = clock?.visit?.id === p.visitId;
  if (p.kind === "start") return p.clockOnly ? !onIt : status === "scheduled" || status === "en_route";
  return (Boolean(p.complete) && status === "in_progress") || (Boolean(p.stopClock) && onIt);
}

// ---------------------------------------------------------------------------------------------
// What the geofence knows, kept on the phone
// ---------------------------------------------------------------------------------------------

const PREFIX = "jobly-geofence:";
export const geofenceKey = (companyId: string, userId: string, day: string) => `${PREFIX}${companyId}:${userId}:${day}`;

/**
 * What this page last knew, for a phone that wouldn't keep it. Without this, a phone whose storage
 * is full or off would start from nothing at every look (two fixes in a row never add up, so it
 * never fires), or from something old it once kept (the same arrival fires again and again).
 */
const remembered = new Map<string, { state: GeofenceState; stored: boolean }>();

export function loadGeofence(key: string): GeofenceState {
  const mine = remembered.get(key);
  // The phone didn't take the last save: this page's own copy is the newest there is.
  if (mine && !mine.stored) return mine.state;
  try {
    const saved = JSON.parse(localStorage.getItem(key) ?? "null") as GeofenceState | null;
    return saved && typeof saved === "object" && saved.sites && typeof saved.sites === "object" ? saved : emptyGeofence();
  } catch {
    return mine?.state ?? emptyGeofence(); // Storage turned off, or something unreadable: what this page knows, else start again.
  }
}

export function saveGeofence(key: string, state: GeofenceState) {
  let stored = false;
  try {
    localStorage.setItem(key, JSON.stringify(state));
    stored = true;
    // Other days' are done with.
    const mine = key.slice(0, key.lastIndexOf(":") + 1);
    for (let i = localStorage.length - 1; i >= 0; i--) {
      const k = localStorage.key(i);
      if (k && k.startsWith(mine) && k !== key) localStorage.removeItem(k);
    }
  } catch {
    // Not kept by the phone: remembered here for as long as the page is open, and at worst an arrival is noticed again after a reload.
  }
  remembered.set(key, { state, stored });
}

/** For the tests: a page opened afresh. */
export function forgetGeofence() {
  remembered.clear();
  prompts = [];
  promptsKey = null;
}

/** The visits the geofence watches: today's, that this person is on, at a property with a point on the map, in the day's order (which says which is next). */
export function geofenceSites(visits: readonly MyDayVisit[] | undefined): GeofenceSite[] {
  return [...(visits ?? [])]
    .sort(dayOrder)
    .filter((v) => v.mine !== false && v.property?.lat != null && v.property?.lng != null && v.status !== "completed" && v.status !== "cancelled")
    .map((v) => ({ visitId: v.id, lat: v.property!.lat!, lng: v.property!.lng!, place: v.property!.line1 || v.title, status: v.status }));
}

/**
 * The visits a clock tap by this person touches, for core noteTap: the one it goes onto, the one
 * it leaves (their clock as this phone shows it), and one it leaves only if still on it.
 */
export function tappedVisits(change: ClockChange, userId: string, running: Pick<ShownClock, "visit"> | null | undefined): string[] {
  if (change.geofence || !change.who.includes(userId)) return [];
  return [...new Set([change.target?.visit?.id, running?.visit?.id, change.fromVisit].filter((id): id is string => Boolean(id)))];
}

// ---------------------------------------------------------------------------------------------
// On the phone
// ---------------------------------------------------------------------------------------------

/** "Clock started at 12 Oak St" and the like: what the phone did by itself, said as it happens. */
export function actionWords(action: GeofenceAction, place: string): string | null {
  if (action.kind === "start-clock") return t("Clock started at {place}", { place });
  // Leaving only ever moves the clock onto driving (core geofence: never off the clock by itself).
  if (action.kind === "stop-clock") return t("You left {place}, so your clock is on driving", { place });
  return null;
}

/** A buzz, and the phone's own notification for someone who allowed Jobly's. Neither is promised. */
function buzz(title: string, body: string, visitId: string) {
  try {
    navigator.vibrate?.([200, 100, 200]);
  } catch {
    // Not every phone can.
  }
  if (typeof Notification === "undefined" || Notification.permission !== "granted" || !navigator.serviceWorker) return;
  void navigator.serviceWorker.ready
    .then((sw) => sw.showNotification(title, { body, tag: `geofence:${visitId}`, icon: "/icon-192.png", badge: "/icon-192.png", data: { link: `/field/visits/${visitId}` } }))
    .catch(() => undefined);
}

/** Their clock as the clock card shows it now, waiting taps included. */
const shownClock = (queryClient: QueryClient, companyId: string, userId: string) => queryClient.getQueryData<ShownClock | null>(["running-timer", companyId, userId]) ?? null;

/** How long a look may go unanswered before the next is tried anyway: the phone's own time limit is 20 seconds, and a page put away mid-look sometimes never hears back at all. */
export const LOOK_WATCHDOG_MS = 45_000;

/**
 * Looks where the phone is, again and again, for as long as a screen wants it: one look at a time,
 * the next as `plan` says. A look the phone never answers (neither a position nor an error: it
 * happens when the page is put away mid-look) is given up on after a while, so the looks go on.
 * Returns how to stop, and `now` to look at once (the page is back on the screen).
 */
export function watchPlace(options: {
  geolocation: Pick<Geolocation, "getCurrentPosition">;
  onFix: (fix: Fix) => void;
  /** The phone refused (true), or answered again after refusing (false). Looks stop while it refuses. */
  onDenied: (denied: boolean) => void;
  plan: (last: Fix | null) => { delayMs: number; precise: boolean };
}): { stop: () => void; now: () => void } {
  let stopped = false;
  /** The look still waited on (0: none). An answer to an older one is used if it's a fix, and otherwise ignored. */
  let looking = 0;
  let looks = 0;
  let next: ReturnType<typeof setTimeout> | undefined;
  let watchdog: ReturnType<typeof setTimeout> | undefined;
  let last: Fix | null = null;

  const later = () => {
    clearTimeout(next);
    if (stopped) return;
    const plan = options.plan(last);
    next = setTimeout(() => look(plan.precise), plan.delayMs);
  };
  const look = (precise: boolean) => {
    if (stopped || looking) return;
    const mine = (looking = ++looks);
    const done = () => {
      if (looking !== mine) return false;
      looking = 0;
      clearTimeout(watchdog);
      return true;
    };
    watchdog = setTimeout(() => {
      if (done() && !stopped) later();
    }, LOOK_WATCHDOG_MS);
    options.geolocation.getCurrentPosition(
      (p) => {
        const current = done();
        if (stopped) return;
        options.onDenied(false);
        const fix: Fix = { lat: p.coords.latitude, lng: p.coords.longitude, accuracy: p.coords.accuracy, at: p.timestamp || Date.now() };
        if (!last || fix.at > last.at) last = fix;
        options.onFix(fix);
        if (current) later();
      },
      (e) => {
        if (!done() || stopped) return;
        // Said on the card; asked again when the screen is opened again.
        if (e.code === e.PERMISSION_DENIED) return options.onDenied(true);
        later();
      },
      { enableHighAccuracy: precise, timeout: 20_000, maximumAge: 15_000 },
    );
  };
  look(true);
  return {
    stop: () => {
      stopped = true;
      clearTimeout(next);
      clearTimeout(watchdog);
    },
    now: () => {
      clearTimeout(next);
      look(true);
    },
  };
}

/**
 * Runs the clock at the property while the screen that calls it is open. Returns whether it's on
 * for this person, and whether the phone refused to say where it is.
 */
export function useGeofence(): { mode: "off" | "remind" | "clock"; watching: boolean; denied: boolean } {
  const session = useSession();
  const queryClient = useQueryClient();
  const setting = geofenceSetting(session.company.settings);
  // Turns on as the notice is acknowledged, without the page loading again.
  useSyncExternalStore(subscribeNotices, noticesVersion);
  const on = setting.mode !== "off" && keepsTime(session) && mayUsePlace(session, "clock_at_property");
  // Only read where the company has it on: a visit's screen doesn't fetch the schedule for nothing.
  const day = useMyDay(on);
  // Loaded so their clock is on hand (shownClock) when a look needs it.
  useRunningTimer(session.company.id, session.userId, on);
  const sites = on ? geofenceSites(day.data?.today) : [];
  const key = geofenceKey(session.company.id, session.userId, todayIn(session.company.timezone));
  const [denied, setDenied] = useState(false);
  // Sent by the action registered for it (fieldActions.ts), as the clock card's taps are.
  const clock = useMutation({
    mutationKey: ["clock"],
    scope: FIELD_SCOPE,
    // Said as it happened (actionWords), not again when it reaches the server.
    meta: { success: () => null },
    onMutate: (change: ClockChange) => showClockTap(queryClient, { key: "clock", change }),
    onSettled: () => {
      for (const k of ["running-timer", "time", "field", "field-visit", "crew-clock"]) void queryClient.invalidateQueries({ queryKey: [k] });
    },
  });

  // The latest of everything, for looks that happen between renders.
  const now = useRef({ session, setting, sites, all: [] as string[], visits: [] as MyDayVisit[], key, clock: clock.mutate });
  now.current = { session, setting, sites, all: (day.data?.today ?? []).map((v) => v.id), visits: day.data?.today ?? [], key, clock: clock.mutate };

  // A clock tap of their own, anywhere in the app, takes the visits it touches off the geofence while they're there.
  useEffect(() => {
    if (!on) return;
    return queryClient.getMutationCache().subscribe((event) => {
      if (event.type !== "updated" || event.action.type !== "pending" || event.mutation.options.mutationKey?.[0] !== "clock") return;
      const change = event.mutation.state.variables as ClockChange | undefined;
      const { session: s, key: k } = now.current;
      if (!change || change.companyId !== s.company.id) return;
      const ids = tappedVisits(change, s.userId, shownClock(queryClient, s.company.id, s.userId));
      if (ids.length) saveGeofence(k, noteTap(loadGeofence(k), ids));
    });
  }, [on, queryClient]);

  // The questions the phone kept for this person and day: still there after the page loads again.
  useEffect(() => {
    if (on) restorePrompts(key);
  }, [on, key]);

  const watching = on && sites.length > 0 && typeof navigator !== "undefined" && Boolean(navigator.geolocation);
  useEffect(() => {
    if (!watching) return;

    const act = (action: GeofenceAction, fix: Fix) => {
      const { session: s, visits, clock: send } = now.current;
      const visit = visits.find((v) => v.id === action.visitId);
      if (!visit) return null;
      const place = visit.property?.line1 || visit.title;
      if (action.kind === "start-clock" || action.kind === "stop-clock") {
        // Where the phone was, only where the company keeps that; six places is about 10 cm.
        const where: ClockPlace | undefined = !recordsPlaces(s.company)
          ? undefined
          : mayUsePlace(s, "clock_location") ? { lat: Number(fix.lat.toFixed(6)), lng: Number(fix.lng.toFixed(6)), accuracy: Math.round(fix.accuracy) } : NOT_YET;
        const target: ClockTarget | null =
          action.kind === "start-clock" ? { category: "visit", visit: { id: visit.id, jobId: visit.job?.id ?? null, title: visit.title } } : { category: "drive" };
        const change: ClockChange = { ...clockChange(s, [s.userId], target, where, new Date(action.at).toISOString()), geofence: true, ...(action.kind === "stop-clock" && { fromVisit: visit.id }) };
        send(change);
        const words = actionWords(action, place)!;
        toast.success(words, onlineManager.isOnline() ? undefined : { description: t("Saved on this phone. It sends when you have signal.") });
        return words;
      }
      const prompt: GeofencePrompt =
        action.kind === "ask-start"
          ? { id: `start:${visit.id}`, kind: "start", visitId: visit.id, jobId: visit.job?.id ?? null, title: visit.title, place, clockOnly: action.clockOnly }
          : { id: `finish:${visit.id}`, kind: "finish", visitId: visit.id, jobId: visit.job?.id ?? null, title: visit.title, place, complete: action.complete, stopClock: action.stopClock };
      return prompt;
    };

    const handle = (fix: Fix) => {
      const { session: s, setting: g, sites: watched, all, visits, key: k } = now.current;
      const before = keepSites(loadGeofence(k), all);
      const running = shownClock(queryClient, s.company.id, s.userId);
      // Start questions still waiting on the screen: another visit at the same spot waits its turn behind them.
      const asking = prompts.filter((p) => p.kind === "start" && promptStands(p, visits.find((v) => v.id === p.visitId)?.status, running)).map((p) => p.visitId);
      const { state, events, actions } = geofenceStep(before, fix, g.radius, {
        mode: g.mode, sites: watched, clock: running && { category: running.category, visitId: running.visit?.id ?? null }, day: onDayClock(s), asking,
      });
      saveGeofence(k, state);
      // Gone from a property: "You're at 12 Oak St. Start the visit?" no longer holds.
      for (const e of events) if (e.kind === "left") dismissPrompt(`start:${e.visitId}`);
      // What the phone did, then what it asks, one question per visit with what it did above it.
      const done = new Map<string, string>();
      for (const action of actions) {
        const result = act(action, fix);
        if (typeof result === "string") done.set(action.visitId, result);
        else if (result) {
          const prompt = { ...result, done: done.get(result.visitId) };
          askPrompt(prompt);
          const text = promptText(prompt);
          buzz(text.title, prompt.done ? `${prompt.done}. ${text.question}` : text.question, prompt.visitId);
        }
      }
      // Done with nothing to ask: still buzzed, so they know.
      for (const [visitId, words] of done) if (!actions.some((a) => a.visitId === visitId && a.kind.startsWith("ask"))) buzz(words, "", visitId);
    };

    const looks = watchPlace({
      geolocation: navigator.geolocation,
      onFix: handle,
      onDenied: setDenied,
      plan: (last) => {
        const { sites: watched, setting: g, key: k } = now.current;
        return nextLook(loadGeofence(k), last, watched, g.radius);
      },
    });
    // Back on the screen (the phone paused it in the background): look at once.
    const onVisible = () => {
      if (document.visibilityState === "visible") looks.now();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      looks.stop();
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [watching, key, queryClient]);

  return { mode: on ? setting.mode : "off", watching, denied };
}
