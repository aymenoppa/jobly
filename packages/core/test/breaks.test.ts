import { describe, expect, it } from "vitest";
import { BREAK_PAY_HINTS, breakPay, isUnpaidBreak } from "../src/breaks";

const at = (minutes: number) => new Date(Date.parse("2026-10-24T16:00:00Z") + minutes * 60_000).toISOString();
const entry = (category: string, minutes: number | null) => ({ category, started_at: at(0), ended_at: minutes === null ? null : at(minutes) });

describe("what the office is told under the breaks setting", () => {
  it("says what the usual choice does to a break of 21 to 29 minutes, and doesn't claim that follows federal rules", () => {
    const hint = BREAK_PAY_HINTS.short_paid;
    expect(hint).toContain("Breaks of 20 minutes or less count as paid time, and longer ones don't, so a 25-minute break is unpaid here.");
    // 29 CFR 785.19(a): "Ordinarily 30 minutes or more is long enough for a bona fide meal period."
    expect(hint).toContain("a meal break that needn't be paid is ordinarily 30 minutes or more with the person fully off duty");
    expect(hint).toContain("If your crew takes breaks of 21 to 29 minutes, choose Always paid or check your state's rules.");
    expect(hint).not.toMatch(/follows federal rules/i);
    for (const text of Object.values(BREAK_PAY_HINTS)) expect(text).not.toMatch(/This follows/);
  });

  it("is what it does: a 25-minute break is unpaid under the usual choice", () => {
    expect(isUnpaidBreak({ category: "break", started_at: "2026-10-24T16:00:00Z", ended_at: "2026-10-24T16:25:00Z" }, "short_paid")).toBe(true);
    expect(isUnpaidBreak({ category: "break", started_at: "2026-10-24T16:00:00Z", ended_at: "2026-10-24T16:25:00Z" }, "paid")).toBe(false);
  });
});

describe("paid and unpaid breaks", () => {
  it("pays short breaks only unless the company chose otherwise", () => {
    expect(breakPay({})).toBe("short_paid");
    expect(breakPay(null)).toBe("short_paid");
    expect(breakPay({ clock: { breaks: "unpaid" } })).toBe("unpaid");
    expect(breakPay({ clock: { breaks: "paid", record_location: false } })).toBe("paid");
    expect(breakPay({ clock: { breaks: "sometimes" } })).toBe("short_paid");
  });

  it("pays a short rest break and not a lunch", () => {
    expect(isUnpaidBreak(entry("break", 10), "short_paid")).toBe(false);
    expect(isUnpaidBreak(entry("break", 20), "short_paid")).toBe(false);
    expect(isUnpaidBreak(entry("break", 30), "short_paid")).toBe(true);
  });

  it("judges a break still running on its length so far", () => {
    expect(isUnpaidBreak(entry("break", null), "short_paid", Date.parse(at(15)))).toBe(false);
    expect(isUnpaidBreak(entry("break", null), "short_paid", Date.parse(at(45)))).toBe(true);
  });

  it("pays every break, or none, when the company says so", () => {
    expect(isUnpaidBreak(entry("break", 45), "paid")).toBe(false);
    expect(isUnpaidBreak(entry("break", 5), "unpaid")).toBe(true);
  });

  it("never leaves out work, driving or shop time", () => {
    for (const category of ["visit", "assessment", "drive", "shop", "other"]) expect(isUnpaidBreak(entry(category, 600), "unpaid")).toBe(false);
  });
});
