/**
 * Clock taps from the clock card and the crew clock (fieldActions.setClock, clockTaps.ts): each is
 * dated when it was tapped, so sent late it still lands where it was made; a tap sent twice changes
 * nothing more; one person never has two clocks running and a stop never ends a clock that started
 * after it; and a tap that lost to something newer (the office started a clock meanwhile) says so
 * instead of failing. And what the clock cards show while taps wait on the phone.
 */
import { QueryClient } from "@tanstack/react-query";
import { beforeEach, describe, expect, it, vi } from "vitest";

// time_entries as the database holds them, with its own rules: an id is used once, and one clock
// runs per person (20261112000410_one_running_clock.sql): a clock that starts stops the one running
// before it, and one that arrives late, dated before the clock running now, ends where that began.
type Entry = { id: string; company_id: string; user_id: string; visit_id: string | null; job_id: string | null; category: string; started_at: string; ended_at: string | null; in_place?: unknown; out_place?: unknown; geofence_in?: boolean; geofence_out?: boolean };
const db = { entries: [] as Entry[], made: 0 };
const at = (time: string) => `2026-10-17T${time}:00.000Z`;
const ms = (iso: string) => Date.parse(iso);

vi.mock("../src/lib/api", async () => {
  const { ApiError } = await vi.importActual<typeof import("../src/lib/errors")>("../src/lib/errors");
  const table = () => {
    const filters: Array<(r: Entry) => boolean> = [];
    let update: Partial<Entry> | null = null;
    let limit = Infinity;
    const value = (r: Entry, k: string) => (r as unknown as Record<string, unknown>)[k];
    // Times are compared as moments, as the database does.
    const moment = (v: unknown) => (typeof v === "string" && /^\d{4}-/.test(v) ? ms(v) : (v as number));
    const q = {
      select: () => q,
      update: (values: Partial<Entry>) => ((update = values), q),
      insert: (rows: Array<Partial<Entry>>) => {
        if (rows.some((row) => row.id && db.entries.some((e) => e.id === row.id))) return Promise.resolve({ data: null, error: new ApiError("That already exists.", 409, "23505") });
        for (const row of rows) {
          const entry: Entry = { id: row.id ?? `db-${++db.made}`, visit_id: null, job_id: null, ended_at: null, ...row } as Entry;
          const running = db.entries.filter((e) => e.user_id === entry.user_id && e.ended_at === null);
          const later = running.filter((e) => ms(e.started_at) >= ms(entry.started_at)).map((e) => e.started_at).sort()[0];
          if (later) entry.ended_at = later;
          else running.forEach((e) => (e.ended_at = entry.started_at));
          db.entries.push(entry);
        }
        return Promise.resolve({ data: null, error: null });
      },
      eq: (k: string, v: unknown) => (filters.push((r) => value(r, k) === v || (k.endsWith("_at") && value(r, k) != null && moment(value(r, k)) === moment(v))), q),
      in: (k: string, v: unknown[]) => (filters.push((r) => v.includes(value(r, k))), q),
      is: (k: string, v: unknown) => (filters.push((r) => (value(r, k) ?? null) === v), q),
      lt: (k: string, v: string) => (filters.push((r) => value(r, k) != null && moment(value(r, k)) < moment(v)), q),
      lte: (k: string, v: string) => (filters.push((r) => value(r, k) != null && moment(value(r, k)) <= moment(v)), q),
      gt: (k: string, v: string) => (filters.push((r) => value(r, k) != null && moment(value(r, k)) > moment(v)), q),
      limit: (n: number) => ((limit = n), q),
      then: (resolve: (r: unknown) => unknown, reject: (e: unknown) => unknown) => {
        const rows = db.entries.filter((r) => filters.every((f) => f(r))).slice(0, limit);
        if (update) rows.forEach((r) => Object.assign(r, update));
        return Promise.resolve({ data: rows.map((r) => ({ ...r })), error: null }).then(resolve, reject);
      },
    };
    return q;
  };
  return { api: {}, supabase: () => ({ from: () => table() }), unwrap: (r: { data: unknown; error: unknown }) => { if (r.error) throw r.error; return r.data; } };
});

const { setClock } = await import("../src/features/field/fieldActions");
const { clockAfter, clockChange, clockLost, clockSaved, crewAfter, showClockTap, withWaitingTaps } = await import("../src/features/field/clockTaps");
type ClockChange = import("../src/features/field/clockTaps").ClockChange;
type ClockTarget = import("../src/features/field/clockTaps").ClockTarget;

const me = { userId: "ray", company: { id: "c1" } };
const tapAt = (time: string, target: ClockTarget | null, who = ["ray"], place?: { lat: number; lng: number; accuracy: number }) => clockChange(me, who, target, place, at(time));
const drive: ClockTarget = { category: "drive" };
const shop: ClockTarget = { category: "shop" };
const visit: ClockTarget = { category: "visit", visit: { id: "v1", jobId: "j1", title: "Gutters" } };
/** Someone's time as "what, from, to" in the order it began. */
const timeOf = (userId: string) =>
  db.entries.filter((e) => e.user_id === userId).sort((a, b) => ms(a.started_at) - ms(b.started_at)).map((e) => [e.visit_id ?? e.category, e.started_at.slice(11, 16), e.ended_at?.slice(11, 16) ?? null]);
/** The office (or a crew lead, or another phone) starts a clock for someone, as the database takes it. */
const officeStarts = (userId: string, category: string, time: string) => {
  db.entries.filter((e) => e.user_id === userId && e.ended_at === null).forEach((e) => (e.ended_at = at(time)));
  db.entries.push({ id: `office-${++db.made}`, company_id: "c1", user_id: userId, visit_id: null, job_id: null, category, started_at: at(time), ended_at: null });
};
/** What must hold whatever was sent, in whatever order: one running clock each, and nothing ends before it starts. */
const sound = () => {
  for (const userId of new Set(db.entries.map((e) => e.user_id))) expect(db.entries.filter((e) => e.user_id === userId && e.ended_at === null).length, `${userId}'s running clocks`).toBeLessThanOrEqual(1);
  for (const e of db.entries) if (e.ended_at) expect(ms(e.ended_at), `${e.category} ${e.started_at}`).toBeGreaterThan(ms(e.started_at));
};

beforeEach(() => {
  db.entries = [];
  db.made = 0;
});

describe("a clock tap, sent", () => {
  it("starts a clock at the time it was tapped, stopping the one that was running, with where the phone was", async () => {
    const yard = { lat: 40.1, lng: -75.1, accuracy: 20 };
    const site = { lat: 40.0004, lng: -75.0003, accuracy: 12 };
    expect(await setClock(tapAt("09:00", drive, ["ray"], yard))).toEqual({ lost: [] });
    await setClock(tapAt("09:40", visit, ["ray"], site));
    expect(timeOf("ray")).toEqual([["drive", "09:00", "09:40"], ["v1", "09:40", null]]);
    const [first, second] = db.entries;
    expect([first!.in_place, first!.out_place, second!.in_place]).toEqual([yard, site, site]);
    expect([second!.category, second!.job_id]).toEqual(["visit", "j1"]);
    await setClock(tapAt("12:00", null, ["ray"], site));
    expect(timeOf("ray")).toEqual([["drive", "09:00", "09:40"], ["v1", "09:40", "12:00"]]);
    expect(db.entries[1]!.out_place).toEqual(site);
    sound();
  });

  it("lands where it was tapped when it's sent hours later, in the order the taps were made", async () => {
    // A morning with no signal: Driving at 9:00, the shop at 10:00, Stop at 12:00, all sent at 3:00.
    for (const tap of [tapAt("09:00", drive), tapAt("10:00", shop), tapAt("12:00", null)]) await setClock(tap);
    expect(timeOf("ray")).toEqual([["drive", "09:00", "10:00"], ["shop", "10:00", "12:00"]]);
    sound();
  });

  it("adds one clock when the same tap is sent twice, and a Stop sent twice changes nothing more", async () => {
    const start = tapAt("09:00", drive);
    const stop = tapAt("11:00", null);
    await setClock(start);
    await setClock(start);
    expect(timeOf("ray")).toEqual([["drive", "09:00", null]]);
    await setClock(stop);
    // Both again, after the app closed before it heard back: the start isn't added a second time.
    expect(await setClock(start)).toEqual({ lost: [] });
    expect(await setClock(stop)).toEqual({ lost: [] });
    expect(timeOf("ray")).toEqual([["drive", "09:00", "11:00"]]);
    // And later, with another clock running since: the old taps don't touch it.
    await setClock(tapAt("13:00", shop));
    await setClock(start);
    expect(timeOf("ray")).toEqual([["drive", "09:00", "11:00"], ["shop", "13:00", null]]);
    sound();
  });

  it("gives each clock it starts an id made on the phone", () => {
    const change = tapAt("09:00", drive, ["ray", "sam"]);
    expect(Object.keys(change.entryIds!)).toEqual(["ray", "sam"]);
    expect(change.entryIds!.ray).toMatch(/^[0-9a-f-]{36}$/);
    expect(change.entryIds!.ray).not.toBe(change.entryIds!.sam);
    expect(tapAt("09:00", null)).not.toHaveProperty("entryIds");
    expect(change.at).toBe(at("09:00"));
  });

  it("leaves someone already on that visit's clock as they are", async () => {
    await setClock(tapAt("09:00", visit));
    await setClock(tapAt("09:30", visit));
    expect(timeOf("ray")).toEqual([["v1", "09:00", null]]);
  });
});

describe("a clock tap that arrives after the office changed the clock", () => {
  it("doesn't stop a clock that started after the Stop was tapped, and says so", async () => {
    await setClock(tapAt("09:00", drive));
    // Ray tapped Stop at 11:00 with no signal; at 11:30 the office clocked him in at the shop.
    officeStarts("ray", "shop", "11:30");
    const stop = tapAt("11:00", null);
    const result = await setClock(stop);
    expect(result).toEqual({ lost: ["ray"] });
    expect(timeOf("ray")).toEqual([["drive", "09:00", "11:30"], ["shop", "11:30", null]]);
    expect(clockSaved(result, stop)).toBeNull();
    const note = clockLost(result, stop)!;
    expect(note.title).toBe("Your clock was changed after you tapped");
    expect(note.body).toMatch(/^Stop at \d{1,2}:00 [AP]M arrived after a newer clock had started, so your clock stays as it is now\. Check Timesheets if that's wrong\.$/);
    sound();
  });

  it("changes nothing when a late start's time is already on record, and saves it up to the newer clock when it isn't", async () => {
    // On record: Ray was driving from 9:00 when the office moved him to the shop at 11:30. His own
    // "Other work" from 10:00 arrives after that.
    await setClock(tapAt("09:00", drive));
    officeStarts("ray", "shop", "11:30");
    const late = tapAt("10:00", { category: "other" });
    expect(await setClock(late)).toEqual({ lost: ["ray"] });
    expect(timeOf("ray")).toEqual([["drive", "09:00", "11:30"], ["shop", "11:30", null]]);
    expect(clockLost({ lost: ["ray"] }, late)!.body).toContain("Other work at ");
    // Not on record: Sam's clock was off when he tapped Driving at 10:00, and the office clocked him
    // in at 11:30. His hour and a half is kept, ending where the office's clock began.
    officeStarts("sam", "shop", "11:30");
    expect(await setClock(clockChange({ userId: "sam", company: { id: "c1" } }, ["sam"], drive, undefined, at("10:00")))).toEqual({ lost: ["sam"] });
    expect(timeOf("sam")).toEqual([["drive", "10:00", "11:30"], ["shop", "11:30", null]]);
    sound();
  });

  it("goes through as usual when nothing newer is in the way", async () => {
    const start = tapAt("09:00", drive);
    const result = await setClock(start);
    expect(clockLost(result, start)).toBeNull();
    expect(clockSaved(result, start)).toBe("Driving: clock started");
    expect(clockSaved({ lost: [] }, tapAt("09:00", visit))).toBe("Gutters: clock started");
    expect(clockSaved({ lost: [] }, tapAt("17:00", null))).toBe("Clock stopped");
    expect(clockSaved({ lost: [] }, tapAt("17:00", null), { day: true })).toBe("Clock stopped for the day");
  });
});

describe("the crew clock", () => {
  const lead = { userId: "lou", company: { id: "c1" } };
  const names: Record<string, string> = { ray: "Ray", sam: "Sam", tess: "Tess" };
  const nameOf = (id: string) => names[id] ?? "Crew member";

  it("clocks everyone in, switches them and clocks them out with one tap each, at the time tapped", async () => {
    const crew = ["lou", "ray", "sam"];
    await setClock(clockChange(lead, crew, visit, undefined, at("08:00")));
    await setClock(clockChange(lead, crew, { category: "break" }, undefined, at("12:00")));
    await setClock(clockChange(lead, crew, visit, undefined, at("12:30")));
    const out = clockChange(lead, crew, null, undefined, at("16:00"));
    expect(await setClock(out)).toEqual({ lost: [] });
    for (const id of crew) expect(timeOf(id)).toEqual([["v1", "08:00", "12:00"], ["break", "12:00", "12:30"], ["v1", "12:30", "16:00"]]);
    expect(clockSaved({ lost: [] }, out, { nameOf })).toBe("Clocked out 3 people");
    expect(clockSaved({ lost: [] }, clockChange(lead, ["ray"], visit, undefined, at("08:00")), { nameOf })).toBe("Clocked in Ray");
    sound();
  });

  it("leaves the one already on the visit as they are, and tells the lead whose clock a late tap lost to", async () => {
    await setClock(clockChange({ userId: "ray", company: { id: "c1" } }, ["ray"], visit, undefined, at("07:45")));
    officeStarts("sam", "shop", "09:00");
    // The lead's "clock everyone in" from 8:00, sent after both.
    const change = clockChange(lead, ["lou", "ray", "sam"], visit, undefined, at("08:00"));
    const result = await setClock(change);
    expect(timeOf("ray")).toEqual([["v1", "07:45", null]]);
    expect(timeOf("lou")).toEqual([["v1", "08:00", null]]);
    expect(timeOf("sam")).toEqual([["v1", "08:00", "09:00"], ["shop", "09:00", null]]);
    expect(result).toEqual({ lost: ["sam"] });
    expect(clockLost(result, change, nameOf)).toEqual({
      title: "Sam's clock was changed after you tapped",
      body: expect.stringMatching(/^Gutters at .* arrived after a newer clock had started, so it stays as it is now\. Check Timesheets if that's wrong\.$/),
    });
    expect(clockLost({ lost: ["sam", "tess"] }, change, nameOf)!.title).toBe("2 people's clocks were changed after you tapped");
    sound();
  });
});

describe("what the clock cards show while taps wait on the phone", () => {
  const running = (category: string, time: string, onVisit?: string) => ({ id: "e1", category, started_at: at(time), visit: onVisit ? { id: onVisit, title: "Gutters" } : null });
  const statusTap = (status: string, time: string, extra: object = {}) => ({ key: "visit-status" as const, title: "Gutters", change: { companyId: "c1", userId: "ray", visitId: "v1", jobId: "j1", status, at: at(time), clock: true, ...extra } });
  const clockTap = (change: ClockChange) => ({ key: "clock" as const, change });

  it("shows a clock tap at once: started, switched or stopped", () => {
    expect(clockAfter(null, clockTap(tapAt("09:00", drive)), "ray")).toMatchObject({ category: "drive", started_at: at("09:00"), visit: null });
    expect(clockAfter(running("drive", "09:00"), clockTap(tapAt("09:40", visit)), "ray")).toMatchObject({ category: "visit", started_at: at("09:40"), visit: { id: "v1", title: "Gutters" } });
    expect(clockAfter(running("drive", "09:00"), clockTap(tapAt("12:00", null)), "ray")).toBeNull();
    // Someone else's tap, or a clock that began after the tap, isn't touched.
    expect(clockAfter(running("drive", "09:00"), clockTap(tapAt("12:00", null)), "sam")).toEqual(running("drive", "09:00"));
    expect(clockAfter(running("shop", "13:00"), clockTap(tapAt("12:00", null)), "ray")).toEqual(running("shop", "13:00"));
    // Shown twice (at the tap, then over what the server says), it reads the same.
    const once = clockAfter(null, clockTap(tapAt("09:00", drive)), "ray");
    expect(clockAfter(once, clockTap(tapAt("09:00", drive)), "ray")).toEqual(once);
  });

  it("shows what a visit's taps do to the clock: Start puts it on the visit and Complete stops it", () => {
    const started = clockAfter(running("drive", "09:00"), statusTap("in_progress", "09:40"), "ray");
    expect(started).toMatchObject({ category: "visit", started_at: at("09:40"), visit: { id: "v1", title: "Gutters" } });
    expect(clockAfter(started, statusTap("completed", "12:00"), "ray")).toBeNull();
    expect(clockAfter(null, statusTap("en_route", "09:00"), "ray")).toBeNull();
    // Someone without a clock (a sub, mostly) has none to show.
    expect(clockAfter(null, statusTap("in_progress", "09:40", { clock: false }), "ray")).toBeNull();
    // A crewmate on the visit's clock is clocked out when it's finished; one on a break isn't.
    expect(clockAfter(running("visit", "09:45", "v1"), statusTap("completed", "12:00"), "sam")).toBeNull();
    expect(clockAfter(running("break", "11:50"), statusTap("completed", "12:00"), "sam")).toEqual(running("break", "11:50"));
  });

  it("on the whole-day clock, shows On my way starting travel and Complete moving back to it", () => {
    const day = { day: true };
    const onMyWay = clockAfter(null, statusTap("en_route", "09:00", day), "ray");
    expect(onMyWay).toMatchObject({ category: "drive", started_at: at("09:00"), visit: null });
    // Already driving: the drive isn't split.
    expect(clockAfter(running("drive", "08:30"), statusTap("en_route", "09:00", day), "ray")).toEqual(running("drive", "08:30"));
    const onSite = clockAfter(onMyWay, statusTap("in_progress", "09:40", day), "ray");
    expect(clockAfter(onSite, statusTap("completed", "12:00", day), "ray")).toMatchObject({ category: "drive", started_at: at("12:00"), visit: null });
    // A crewmate on the visit's clock goes to travel too; a break stays a break, and no clock stays none.
    expect(clockAfter(running("visit", "09:45", "v1"), statusTap("completed", "12:00", day), "sam")).toMatchObject({ category: "drive", started_at: at("12:00") });
    expect(clockAfter(running("break", "11:50"), statusTap("completed", "12:00", day), "ray")).toEqual(running("break", "11:50"));
    expect(clockAfter(null, statusTap("completed", "12:00", day), "ray")).toBeNull();
    // Never a sub's, whatever the tap says.
    expect(clockAfter(null, statusTap("en_route", "09:00", { day: true, sub: true }), "ray")).toBeNull();
  });

  it("puts the waiting taps, in the order they were made, over what the server last said", async () => {
    const qc = new QueryClient();
    // Nothing gets out: each tap stays waiting.
    qc.setMutationDefaults(["clock"], { mutationFn: () => new Promise(() => undefined) });
    qc.setMutationDefaults(["visit-status"], { mutationFn: () => new Promise(() => undefined) });
    const wait = (key: string, variables: object) => void qc.getMutationCache().build(qc, { mutationKey: [key] }).execute(variables);
    qc.setQueryData(["field-visit", "v1"], { title: "Gutters", status: "scheduled" });
    wait("clock", tapAt("09:00", drive));
    wait("visit-status", statusTap("in_progress", "09:40").change);
    // Another company's tap on the same phone isn't this one's.
    wait("clock", { ...tapAt("10:00", null), companyId: "c2" });
    await Promise.resolve();
    expect(withWaitingTaps(qc, "c1", "ray", null)).toMatchObject({ category: "visit", started_at: at("09:40"), visit: { id: "v1", title: "Gutters" } });
    wait("clock", tapAt("12:00", null));
    await Promise.resolve();
    expect(withWaitingTaps(qc, "c1", "ray", running("shop", "07:00"))).toBeNull();
    expect(withWaitingTaps(qc, "c1", "sam", running("shop", "07:00"))).toEqual(running("shop", "07:00"));
    qc.clear();
  });

  it("shows a tap on the clock cards this phone holds, the crew clock included", () => {
    const qc = new QueryClient();
    qc.setQueryData(["running-timer", "c1", "ray"], null);
    qc.setQueryData(["running-timer", "c2", "ray"], null);
    qc.setQueryData(["crew-clock", "c1", "ray,sam,tess"], [{ ...running("shop", "07:00"), user_id: "tess" }]);
    showClockTap(qc, { key: "clock", change: tapAt("09:00", visit, ["ray", "sam"]) });
    expect(qc.getQueryData(["running-timer", "c1", "ray"])).toMatchObject({ category: "visit", started_at: at("09:00") });
    expect(qc.getQueryData(["running-timer", "c2", "ray"])).toBeNull();
    expect(qc.getQueryData<Array<{ user_id: string; category: string }>>(["crew-clock", "c1", "ray,sam,tess"])!.map((r) => [r.user_id, r.category])).toEqual([["ray", "visit"], ["sam", "visit"], ["tess", "shop"]]);
    showClockTap(qc, { key: "clock", change: tapAt("16:00", null, ["ray", "sam", "tess"]) });
    expect(qc.getQueryData(["crew-clock", "c1", "ray,sam,tess"])).toEqual([]);
    expect(qc.getQueryData(["running-timer", "c1", "ray"])).toBeNull();
    // A crew this phone hasn't loaded isn't guessed at.
    const fresh = new QueryClient();
    showClockTap(fresh, { key: "clock", change: tapAt("09:00", drive) });
    expect(fresh.getQueryData(["crew-clock", "c1", "ray,sam"])).toBeUndefined();
    expect(crewAfter([], ["ray", "sam"], [{ key: "clock", change: tapAt("09:00", drive, ["sam"]) }]).map((r) => r.user_id)).toEqual(["sam"]);
  });
});

describe("the clock at the property (geofence.ts): the phone's own taps", () => {
  const byPhone = (change: ClockChange, fromVisit?: string): ClockChange => ({ ...change, geofence: true, ...(fromVisit && { fromVisit }) });
  const marks = (userId: string) => db.entries.filter((e) => e.user_id === userId).sort((a, b) => ms(a.started_at) - ms(b.started_at)).map((e) => [e.visit_id ?? e.category, Boolean(e.geofence_in), Boolean(e.geofence_out)]);

  it("starts the clock on arriving, dated at the arrival, and marks the clocks it starts and stops", async () => {
    await setClock(tapAt("08:30", drive));
    await setClock(byPhone(tapAt("09:00", visit)));
    expect(timeOf("ray")).toEqual([["drive", "08:30", "09:00"], ["v1", "09:00", null]]);
    expect(marks("ray")).toEqual([["drive", false, true], ["v1", true, false]]);
    sound();
  });

  it("stops only a clock still on that visit when they leave", async () => {
    await setClock(byPhone(tapAt("09:00", visit)));
    await setClock(byPhone(tapAt("11:00", null), "v1"));
    expect(timeOf("ray")).toEqual([["v1", "09:00", "11:00"]]);
    expect(marks("ray")).toEqual([["v1", true, true]]);
    // On a break, or on the next visit, by the time it's sent: left as it is.
    await setClock(tapAt("11:30", { category: "break" }));
    expect(await setClock(byPhone(tapAt("11:45", null), "v1"))).toEqual({ lost: [] });
    expect(timeOf("ray").at(-1)).toEqual(["break", "11:30", null]);
    sound();
  });

  it("moves the clock on the visit to travel on the whole-day clock, and nothing else", async () => {
    await setClock(byPhone(tapAt("09:00", visit)));
    await setClock(byPhone(tapAt("11:00", drive), "v1"));
    expect(timeOf("ray")).toEqual([["v1", "09:00", "11:00"], ["drive", "11:00", null]]);
    expect(marks("ray")).toEqual([["v1", true, true], ["drive", true, false]]);
    // Already off the visit (Complete moved them to travel first): no second drive.
    await setClock(byPhone(tapAt("11:05", drive), "v1"));
    expect(timeOf("ray")).toHaveLength(2);
    sound();
  });

  it("never ends a break, and loses to a tap made after it, as any late tap does", async () => {
    await setClock(tapAt("09:00", { category: "break" }));
    expect(await setClock(byPhone(tapAt("09:10", visit)))).toEqual({ lost: [] });
    expect(timeOf("ray")).toEqual([["break", "09:00", null]]);
    officeStarts("sam", "shop", "10:00");
    const result = await setClock(byPhone(clockChange({ userId: "sam", company: { id: "c1" } }, ["sam"], visit, undefined, at("09:55"))));
    expect(result).toEqual({ lost: ["sam"] });
    sound();
  });

  it("never moves a clock that's on another visit, the shop or other work onto the visit it arrives at, however late it's sent", async () => {
    const elm: ClockTarget = { category: "visit", visit: { id: "v2", jobId: "j2", title: "Elm" } };
    // Their clock is on Gutters; the phone notices them inside Elm's circle next door.
    await setClock(tapAt("09:00", visit));
    expect(await setClock(byPhone(tapAt("09:30", elm)))).toEqual({ lost: [] });
    expect(timeOf("ray")).toEqual([["v1", "09:00", null]]);
    // At the shop, or on other work: the same.
    for (const [target, tapped, noticed] of [[shop, "10:00", "10:20"], [{ category: "other" } as ClockTarget, "10:30", "10:50"]] as const) {
      await setClock(tapAt(tapped, target));
      await setClock(byPhone(tapAt(noticed, elm)));
      expect(timeOf("ray").at(-1)![2]).toBeNull();
      expect(timeOf("ray").at(-1)![0]).toBe(target.category);
    }
    // Their own tap moves it, as ever; and from driving, or from nothing, the phone starts it.
    await setClock(tapAt("11:00", drive));
    await setClock(byPhone(tapAt("11:15", elm)));
    expect(timeOf("ray").at(-1)).toEqual(["v2", "11:15", null]);
    sound();
  });

  it("shows the same on the clock cards while it waits: only from that visit, never over a break", () => {
    const elsewhere = (category: string, onVisit?: string) => ({ id: "e1", category, started_at: at("09:00"), visit: onVisit ? { id: onVisit, title: "Elm" } : null });
    for (const clock of [elsewhere("visit", "v2"), elsewhere("shop"), elsewhere("other"), elsewhere("assessment")]) {
      expect(clockAfter(clock, { key: "clock", change: byPhone(tapAt("09:30", visit)) }, "ray")).toEqual(clock);
    }
    expect(clockAfter(null, { key: "clock", change: byPhone(tapAt("09:30", visit)) }, "ray")).toMatchObject({ category: "visit", visit: { id: "v1" } });
    const running = (category: string, time: string, onVisit?: string) => ({ id: "e1", category, started_at: at(time), visit: onVisit ? { id: onVisit, title: "Gutters" } : null });
    const tap = (change: ClockChange) => ({ key: "clock" as const, change });
    expect(clockAfter(running("visit", "09:00", "v1"), tap(byPhone(tapAt("11:00", null), "v1")), "ray")).toBeNull();
    expect(clockAfter(running("visit", "09:00", "v2"), tap(byPhone(tapAt("11:00", null), "v1")), "ray")).toEqual(running("visit", "09:00", "v2"));
    expect(clockAfter(running("break", "09:00"), tap(byPhone(tapAt("09:30", visit))), "ray")).toEqual(running("break", "09:00"));
    expect(clockAfter(running("drive", "08:00"), tap(byPhone(tapAt("09:30", visit))), "ray")).toMatchObject({ category: "visit", visit: { id: "v1" } });
    // A tap of the person's own does end a break.
    expect(clockAfter(running("break", "09:00"), tap(tapAt("09:30", visit)), "ray")).toMatchObject({ category: "visit" });
  });
});
