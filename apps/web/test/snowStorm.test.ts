import { describe, expect, it } from "vitest";
import { progressOf, standingOf } from "../src/features/snow/storm";

// Plows at 2 in and again every 2, salts from half an inch.
const site = { paused: false, located: true, rules: { trigger_in: 2, salt_trigger_in: 0.5, repeat_in: 2 }, told: false };
const stand = (snow: number | null, visits = 0, over: Partial<typeof site> = {}) => {
  const { group, label, tone, note } = standingOf({ ...site, ...over }, snow, visits);
  return [group, label, tone, note];
};

describe("Snow → Storm: where a customer stands for the storm coming", () => {
  it("is to schedule until it has every visit the forecast calls for, and says whether its people know", () => {
    expect(stand(4.5)).toEqual(["schedule", "To schedule", "warning", "Crew hears within the hour, 10am to 10pm"]);
    // With storms scheduling themselves, it says that's coming too.
    expect(standingOf(site, 4.5, 0, true).note).toBe("Crew hears and it's scheduled within the hour, 10am to 10pm");
    expect(stand(4.5, 0, { told: true })).toEqual(["schedule", "To schedule", "warning", "Crew told"]);
    // Two pushes called for and one visit: the forecast grew after it was scheduled.
    expect(stand(4.5, 1, { told: true })).toEqual(["schedule", "1 of 2 scheduled", "warning", "The forecast grew"]);
    expect(stand(4.5, 2)).toEqual(["scheduled", "Scheduled", "good", "2 visits"]);
    expect(stand(1, 1)).toEqual(["scheduled", "Scheduled", "good", undefined]);
  });
  it("is not this storm under its triggers, paused or with no forecast, in plain words", () => {
    expect(stand(0.2)).toEqual(["off", "Below trigger", null, "0.3 in short"]);
    expect(stand(1.5, 0, { rules: { trigger_in: 2 } })).toEqual(["off", "Below trigger", null, "0.5 in short"]);
    expect(stand(9, 0, { paused: true })).toEqual(["off", "Paused", null, "Not checked while the job is paused"]);
    expect(stand(null)).toEqual(["off", "No forecast", null, undefined]);
  });
  it("needs a look when it can't be checked, or its people were told and the forecast has dropped", () => {
    expect(stand(9, 0, { located: false })).toEqual(["check", "No map location", "danger", "Not checked until its address is found"]);
    expect(stand(0.2, 0, { told: true })).toEqual(["check", "Forecast dropped", "warning", "They were told. Let them know if it's off."]);
    expect(stand(0.2, 1, { told: true })[3]).toBe("Told and scheduled. Cancel the visit if it's off.");
  });
});

describe("Snow → Storm: a storm that's here today", () => {
  const v = (...statuses: string[]) => statuses.map((status) => ({ status }));
  it("goes by its least far along visit, and counts the pushes", () => {
    expect(progressOf(v("scheduled"), null, "09:00")).toEqual({ status: "scheduled", late: false, note: undefined });
    expect(progressOf(v("completed", "en_route"), null, "09:00")).toEqual({ status: "en_route", late: false, note: "1 of 2 pushes done" });
    expect(progressOf(v("completed", "in_progress", "en_route"), null, "09:00").status).toBe("in_progress");
    expect(progressOf(v("completed", "completed"), "07:00:00", "09:00")).toEqual({ status: "completed", late: false, note: "2 of 2 pushes done" });
    expect(progressOf([], "07:00:00", "09:00")).toEqual({ status: "unscheduled", late: false });
  });
  it("is late once the time it was to be clear by passes with work left", () => {
    expect(progressOf(v("scheduled"), "07:00:00", "06:59").late).toBe(false);
    expect(progressOf(v("scheduled"), "07:00:00", "07:00")).toEqual({ status: "scheduled", late: true, note: "Due by 7 AM" });
    expect(progressOf(v("completed", "scheduled"), "07:00:00", "11:30").note).toBe("Due by 7 AM · 1 of 2 pushes done");
  });
});
