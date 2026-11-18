import { describe, expect, it } from "vitest";
import { DEPOSIT_LAW_NOTE, scheduleAmounts, scheduleDateProblem, scheduleDueText, scheduleProblem, scheduleRows, type ScheduleRow } from "../src/money";

// The database's private.schedule_amounts and private.schedule_problem do these sums
// (supabase/tests/payment_schedule_test.sql checks the same cases there).
const thirds: ScheduleRow[] = [
  { kind: "percent", value: 30, due: "approval" },
  { kind: "percent", value: 30, due: "work_starts" },
  { kind: "rest", due: "work_done" },
];

describe("what the schedule editor says about deposits", () => {
  it("says some states cap them, with California's and Maryland's figures as the laws give them", () => {
    // Cal. Bus. & Prof. Code 7159.5(a)(3): "one thousand dollars ($1,000) or 10 percent of the contract amount, whichever amount is less".
    expect(DEPOSIT_LAW_NOTE).toContain("California at $1,000 or 10% of the contract price, whichever is less");
    // Md. Bus. Reg. 8-617(b): "a deposit of more than one-third of the home improvement contract price".
    expect(DEPOSIT_LAW_NOTE).toContain("Maryland at one-third of it");
    expect(DEPOSIT_LAW_NOTE).toMatch(/^Some states cap the deposit on a home-improvement contract/);
    expect(DEPOSIT_LAW_NOTE).toContain("Check your state's rules");
  });

  it("changes nothing a schedule may ask for: any share when they approve is still taken", () => {
    expect(scheduleProblem([{ kind: "percent", value: 60, due: "approval" }, { kind: "rest", due: "work_done" }], 10000)).toBeNull();
  });
});

describe("payment schedule sums", () => {
  it("works out percents of the total, and the rest as what's left", () => {
    const sums = scheduleAmounts(thirds, 1000);
    expect(sums.rows.map((r) => r.amount)).toEqual([300, 300, 400]);
    expect(sums).toMatchObject({ fits: true, left: 0 });
  });

  it("follows the total: percents move, amounts stay", () => {
    const rows: ScheduleRow[] = [{ kind: "percent", value: 30, due: "approval" }, { kind: "amount", value: 300, due: "work_starts" }, { kind: "rest", due: "work_done" }];
    expect(scheduleAmounts(rows, 1200).rows.map((r) => r.amount)).toEqual([360, 300, 540]);
    expect(scheduleAmounts(rows, "1200.00").fits).toBe(true);
  });

  it("lets percents that make 100 fit, the last payment taking the cent of rounding", () => {
    const rows: ScheduleRow[] = [{ kind: "percent", value: 33.33, due: "approval" }, { kind: "percent", value: 33.33, due: "by_hand" }, { kind: "percent", value: 33.34, due: "work_done" }];
    const sums = scheduleAmounts(rows, 100.01);
    expect(sums.rows.map((r) => r.amount)).toEqual([33.33, 33.33, 33.35]);
    expect(sums.fits).toBe(true);
    expect(scheduleProblem(rows, 100.01)).toBeNull();
    // Rounds a half cent up, as Postgres does: 12.5% of $0.20 is 2.5 cents.
    expect(scheduleAmounts([{ kind: "percent", value: 12.5, due: "approval" }, { kind: "rest", due: "work_done" }], 0.2).rows.map((r) => r.amount)).toEqual([0.03, 0.17]);
  });

  it("flags amounts that no longer fit, and still never asks for more than the total", () => {
    const rows: ScheduleRow[] = [{ kind: "amount", value: 800, due: "approval" }, { kind: "amount", value: 500, due: "by_hand" }, { kind: "amount", value: 100, due: "work_done" }];
    const sums = scheduleAmounts(rows, 1000);
    expect(sums.rows.map((r) => r.amount)).toEqual([800, 200, 0]);
    expect(sums).toMatchObject({ fits: false, left: -400 });
    expect(scheduleProblem(rows, 1000)).toBe("The payments come to $400.00 more than the total.");
    expect(scheduleProblem([{ kind: "percent", value: 30, due: "approval" }, { kind: "amount", value: 600, due: "work_done" }], 1000)).toBe("The payments come to $100.00 less than the total.");
    expect(scheduleAmounts([{ kind: "percent", value: 30, due: "approval" }, { kind: "amount", value: 600, due: "work_done" }], 1000).left).toBe(100);
  });

  it("needs the rest to leave something", () => {
    expect(scheduleProblem([{ kind: "amount", value: 1000, due: "approval" }, { kind: "rest", due: "work_done" }], 1000)).toBe(
      "The payments before the last come to the whole total, so nothing is left for the rest.",
    );
    expect(scheduleAmounts([{ kind: "rest", due: "approval" }], 0).fits).toBe(false);
  });

  it("says what's wrong with the rows in the database's words", () => {
    const rest: ScheduleRow = { kind: "rest", due: "work_done" };
    expect(scheduleProblem([{ kind: "rest", due: "approval" }, { kind: "amount", value: 5, due: "work_done" }], 1000)).toBe("Only the last payment can be the rest.");
    expect(scheduleProblem([{ kind: "percent", value: 50, due: "approval" }, { kind: "percent", value: 50, due: "approval" }], 1000)).toBe("Only one payment can be due when the quote is approved.");
    expect(scheduleProblem([{ kind: "percent", value: 50, due: "work_done" }, { kind: "percent", value: 50, due: "work_done" }], 1000)).toBe("Only one payment can be due when the work is done.");
    expect(scheduleProblem([{ kind: "percent", value: 50, due: "date" }, rest], 1000)).toBe("Payment 1 needs its date.");
    expect(scheduleProblem([{ kind: "percent", value: 0, due: "approval" }, rest], 1000)).toBe("Payment 1 needs a percent above 0, up to 100.");
    expect(scheduleProblem([{ kind: "amount", value: null, due: "approval" }, rest], 1000)).toBe("Payment 1 needs an amount.");
    expect(scheduleProblem(Array.from({ length: 13 }, () => ({ kind: "amount" as const, value: 1, due: "by_hand" as const })), 13)).toBe("A payment schedule has 12 payments at most.");
    expect(scheduleProblem([{ kind: "percent", value: 25, due: "approval" }, { kind: "amount", value: 750, due: "date", on: "2027-01-04" }], 1000)).toBeNull();
    expect(scheduleProblem([], 1000)).toBeNull();
  });

  it("reads a stored schedule, and anything else as none", () => {
    expect(scheduleRows(null)).toEqual([]);
    expect(scheduleRows({ kind: "rest" })).toEqual([]);
    expect(scheduleRows([thirds[0], "x", null])).toEqual([thirds[0]]);
  });

  it("says when each is due", () => {
    const day = (iso: string) => `day ${iso}`;
    expect(thirds.map((r) => scheduleDueText(r, day))).toEqual(["When the quote is approved", "When the work starts", "When the work is done"]);
    expect(scheduleDueText({ due: "date", on: "2027-03-01" }, day)).toBe("On day 2027-03-01");
    expect(scheduleDueText({ due: "by_hand" }, day)).toBe("When it's invoiced");
    // Days after approval, until approving gives it its day.
    expect(scheduleDueText({ due: "date", after: 30 }, day)).toBe("30 days after the quote is approved");
    expect(scheduleDueText({ due: "date", after: 1 }, day)).toBe("1 day after the quote is approved");
    expect(scheduleDueText({ due: "date", after: 30, on: "2027-03-31" }, day)).toBe("On day 2027-03-31");
    // A copy's or a template's, with its day to set.
    expect(scheduleDueText({ due: "date" }, day)).toBe("On a date");
  });

  it("takes a payment due so many days after approval, a whole number from 1 to 365", () => {
    const rest: ScheduleRow = { kind: "rest", due: "work_done" };
    expect(scheduleProblem([{ kind: "percent", value: 50, due: "date", after: 30 }, rest], 1000)).toBeNull();
    expect(scheduleProblem([{ kind: "percent", value: 50, due: "date", after: 365 }, rest], 1000)).toBeNull();
    for (const after of [0, 366, 2.5, Number.NaN]) {
      expect(scheduleProblem([{ kind: "percent", value: 50, due: "date", after }, rest], 1000)).toBe("Payment 1 needs a number of days, 1 to 365.");
    }
  });

  it("says why a schedule can't go to the client: a day to set, or one already gone", () => {
    const day = (iso: string) => `day ${iso}`;
    const rest: ScheduleRow = { kind: "rest", due: "work_done" };
    expect(scheduleDateProblem([{ kind: "percent", value: 50, due: "approval" }, { kind: "percent", value: 20, due: "date" }, rest], "2026-11-14", day)).toBe("Payment 2 needs its date.");
    expect(scheduleDateProblem([{ kind: "percent", value: 20, due: "date", on: "2026-11-13" }, rest], "2026-11-14", day)).toBe("Payment 1 is due on day 2026-11-13, which has already passed. Give it a new date.");
    expect(scheduleDateProblem([{ kind: "percent", value: 20, due: "date", on: "2026-11-14" }, rest], "2026-11-14", day)).toBeNull();
    expect(scheduleDateProblem([{ kind: "percent", value: 20, due: "date", after: 30 }, rest], "2026-11-14", day)).toBeNull();
    expect(scheduleDateProblem(thirds, "2026-11-14", day)).toBeNull();
  });
});
