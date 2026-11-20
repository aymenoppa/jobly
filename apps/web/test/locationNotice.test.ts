/**
 * The one-time notice of what Jobly collects about where a worker is
 * (features/field/locationNotice.ts): which notices apply, that the phone's position isn't read
 * before they're acknowledged, and that the date is kept on the phone and sent when there's signal.
 */
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";

const store = new Map<string, string>();
vi.stubGlobal("localStorage", {
  getItem: (k: string) => store.get(k) ?? null,
  setItem: (k: string, v: string) => void store.set(k, v),
  removeItem: (k: string) => void store.delete(k),
  key: (i: number) => [...store.keys()][i] ?? null,
  get length() { return store.size; },
});
vi.mock("../src/lib/api", async (importOriginal) => ({ ...(await importOriginal<typeof import("../src/lib/api")>()), supabase: () => null }));

const notice = await import("../src/features/field/locationNotice");
const { clockPlace } = await import("../src/features/field/fieldData");

type Who = Parameters<typeof notice.noticesFor>[0];
const worker = (settings: Record<string, unknown> = {}, over: Partial<Who> = {}): Who => ({ userId: "ray", role: "field_crew", subcontractor: null, company: { id: "co", settings }, ...over } as Who);
const GEOFENCE = { clock: { geofence: { mode: "remind", radius: 200 } } };

beforeEach(() => {
  store.clear();
  notice.forgetNotices();
});

describe("which notices a worker is shown", () => {
  it("says clock-ins save where they are unless the company turned that off", () => {
    expect(notice.noticesFor(worker())).toEqual(["clock_location"]);
    expect(notice.noticesFor(worker({ clock: { record_location: true } }))).toEqual(["clock_location"]);
    expect(notice.noticesFor(worker({ clock: { record_location: false } }))).toEqual([]);
  });

  it("adds the clock at the property when that's on, whether or not places are saved", () => {
    expect(notice.noticesFor(worker(GEOFENCE))).toEqual(["clock_location", "clock_at_property"]);
    expect(notice.noticesFor(worker({ clock: { record_location: false, geofence: { mode: "clock" } } }))).toEqual(["clock_at_property"]);
    expect(notice.noticesFor(worker({ clock: { geofence: { mode: "off" } } }))).toEqual(["clock_location"]);
  });

  it("shows nothing to a sub the office keeps no hours for, and shows it to one on the clock", () => {
    expect(notice.noticesFor(worker(GEOFENCE, { role: "subcontractor", subcontractor: { uses_clock: false } } as Partial<Who>))).toEqual([]);
    expect(notice.noticesFor(worker(GEOFENCE, { role: "subcontractor", subcontractor: { uses_clock: true } } as Partial<Who>))).toEqual(["clock_location", "clock_at_property"]);
  });
});

describe("before the notice is acknowledged", () => {
  it("doesn't ask the phone where it is: a clock tap goes through saying no place was found", async () => {
    const asked = vi.fn();
    vi.stubGlobal("navigator", { geolocation: { getCurrentPosition: asked } });
    expect(await clockPlace(worker())).toEqual({ missing: "unavailable" });
    expect(asked).not.toHaveBeenCalled();
    expect(notice.mayUsePlace(worker(GEOFENCE), "clock_location")).toBe(false);
    expect(notice.mayUsePlace(worker(GEOFENCE), "clock_at_property")).toBe(false);
  });

  it("still sends nothing at all where the company keeps no places", async () => {
    expect(await clockPlace(worker({ clock: { record_location: false } }))).toBeUndefined();
  });

  it("holds nobody back that no notice applies to", () => {
    const sub = worker({}, { role: "subcontractor", subcontractor: { uses_clock: false } } as Partial<Who>);
    expect(notice.mayUsePlace(sub, "clock_location")).toBe(true);
    // The clock at the property is off: nothing to be told about it.
    expect(notice.mayUsePlace(worker(), "clock_at_property")).toBe(true);
  });
});

describe("acknowledging it", () => {
  it("keeps the date on the phone, and the phone's position is read from then on", async () => {
    const who = worker(GEOFENCE);
    expect(notice.noticesToShow(who)).toEqual(["clock_location", "clock_at_property"]);
    notice.acknowledgeHere(who, notice.noticesToShow(who), "2026-11-14T15:00:00.000Z");
    expect(notice.noticesToShow(who)).toEqual([]);
    expect(notice.acknowledgedAt(who, "clock_location")).toBe("2026-11-14T15:00:00.000Z");
    expect(notice.mayUsePlace(who, "clock_at_property")).toBe(true);
    vi.stubGlobal("navigator", { geolocation: { getCurrentPosition: (ok: (p: unknown) => void) => ok({ coords: { latitude: 40.1234567, longitude: -75.7654321, accuracy: 12.4 } }) } });
    expect(await clockPlace(who)).toEqual({ lat: 40.123457, lng: -75.765432, accuracy: 12 });
  });

  it("is per person and per company", () => {
    notice.acknowledgeHere(worker(), ["clock_location"]);
    expect(notice.noticesToShow(worker({}, { userId: "sam" }))).toEqual(["clock_location"]);
    expect(notice.noticesToShow({ ...worker(), company: { id: "other", settings: {} } } as Who)).toEqual(["clock_location"]);
  });

  it("asks again about the clock at the property when the company turns that on later", () => {
    notice.acknowledgeHere(worker(), ["clock_location"]);
    expect(notice.noticesToShow(worker(GEOFENCE))).toEqual(["clock_at_property"]);
  });

  it("waits to be sent until the server has it, with the date they tapped", () => {
    const who = worker(GEOFENCE);
    expect(notice.unsentNotices(who)).toBeNull();
    notice.acknowledgeHere(who, ["clock_location"], "2026-11-14T15:00:00.000Z");
    notice.acknowledgeHere(who, ["clock_at_property"], "2026-11-15T09:00:00.000Z");
    expect(notice.unsentNotices(who)).toEqual({ notices: ["clock_location", "clock_at_property"], at: "2026-11-14T15:00:00.000Z" });
    notice.markSent(who, "clock_location");
    expect(notice.unsentNotices(who)).toEqual({ notices: ["clock_at_property"], at: "2026-11-15T09:00:00.000Z" });
    notice.markSent(who, "clock_at_property");
    expect(notice.unsentNotices(who)).toBeNull();
  });

  it("isn't asked again on a phone they haven't used before: what the server has is learned", () => {
    const who = worker(GEOFENCE);
    notice.learnAcknowledged(who, [{ notice: "clock_location", acknowledged_at: "2026-11-01T12:00:00+00:00" }, { notice: "something_newer", acknowledged_at: "2026-11-01T12:00:00+00:00" }]);
    expect(notice.noticesToShow(who)).toEqual(["clock_at_property"]);
    expect(notice.acknowledgedAt(who, "clock_location")).toBe("2026-11-01T12:00:00+00:00");
    // Nothing to send back for what came from the server.
    expect(notice.unsentNotices(who)).toBeNull();
  });

  it("still holds on a phone that won't keep anything, for as long as the page is open", () => {
    vi.stubGlobal("localStorage", { getItem: () => { throw new Error("off"); }, setItem: () => { throw new Error("off"); } });
    notice.acknowledgeHere(worker(), ["clock_location"]);
    expect(notice.noticesToShow(worker())).toEqual([]);
  });
});

describe("what the notice says, and where", () => {
  const dialog = readFileSync(new URL("../src/features/field/LocationNoticeDialog.tsx", import.meta.url), "utf8");

  it("says what's saved at a clock-in and clock-out, and that the comparing at the property saves nothing", () => {
    expect(dialog).toContain("saves where you are when you clock in and when you clock out");
    expect(dialog).toContain("It isn't saved at any other time.");
    expect(dialog).toContain("it compares where the phone is with the property of your visit");
    expect(dialog).toContain("your position isn't saved and isn't sent anywhere");
    expect(dialog).toContain("The date you tap OK is kept.");
  });

  it("records the date through the database's own function, and only on OK", () => {
    expect(dialog).toContain('rpc("acknowledge_worker_notices", { p_company: session.company.id, p_notices: waiting.notices, p_at: waiting.at })');
    // Closing it acknowledges nothing: it comes back next time.
    expect(dialog).toContain("onClose={() => setLater(true)}");
  });

  it("is on the screens with a clock, and the clock at the property waits for it", () => {
    const read = (file: string) => readFileSync(new URL(`../src/features/field/${file}`, import.meta.url), "utf8");
    expect(read("ClockCard.tsx")).toContain("<LocationNotice />");
    expect(read("FieldVisitPage.tsx")).toContain("<LocationNotice />");
    expect(read("geofence.ts")).toContain('keepsTime(session) && mayUsePlace(session, "clock_at_property")');
    // Every clock tap's place goes through the one gate.
    for (const file of ["ClockCard.tsx", "CrewClockCard.tsx", "GeofenceCard.tsx"]) expect(read(file)).toContain("await clockPlace(session)");
  });
});
