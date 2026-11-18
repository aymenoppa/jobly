import { describe, expect, it } from "vitest";
import { autopayNote, PRICE_CHANGE_COLUMNS, priceChangeGroups, priceChangeOf, priceChangeRows, priceChangeTotals, priceIsFor, type PriceChangeJob } from "../src/priceChange";

const job = (n: number, over: Partial<PriceChangeJob> = {}): PriceChangeJob => ({
  job_id: `j${n}`, number: n, title: `Mow ${n}`, client_id: `c${n}`, client: `Client ${n}`, pricing: "per_visit", schedule: "after_visit",
  old_price: 45, new_price: 47.25, autopay: false, over_limit: false, was_over_limit: false,
  lines: [{ line_id: `l${n}`, name: "Mowing", quantity: 1, unit: "visit", old_price: 45, new_price: 47.25 }],
  ...over,
});
const money = (n: number) => `$${n}`;

describe("what the form asks the database for", () => {
  const form = { direction: "up" as const, kind: "percent" as const, amount: "5", round: "dollar" as const };

  it("a percentage or an amount, up or down, with its rounding", () => {
    expect(priceChangeOf(form)).toEqual({ kind: "percent", value: 5, round: "dollar" });
    expect(priceChangeOf({ ...form, direction: "down", amount: "3.5" })).toEqual({ kind: "percent", value: -3.5, round: "dollar" });
    expect(priceChangeOf({ ...form, kind: "amount", amount: "2", round: "half" })).toEqual({ kind: "amount", value: 2, round: "half" });
    expect(priceChangeOf({ ...form, kind: "amount", direction: "down", amount: "2.50", round: "cent" })).toEqual({ kind: "amount", value: -2.5, round: "cent" });
  });

  it("which lines and which jobs, leaving out what wasn't chosen", () => {
    expect(priceChangeOf({ ...form, lineServiceId: "s1", pick: { service_id: "s2", client_tag: " Commercial ", crew_id: "", job_ids: null } }))
      .toEqual({ kind: "percent", value: 5, round: "dollar", line_service_id: "s1", jobs: { service_id: "s2", client_tag: "Commercial" } });
    expect(priceChangeOf({ ...form, pick: { crew_id: "cr1", job_ids: ["j1", "j2"] } })).toEqual({ kind: "percent", value: 5, round: "dollar", jobs: { crew_id: "cr1", job_ids: ["j1", "j2"] } });
    // Ticked on the list but none of them there: only those, which is none.
    expect(priceChangeOf({ ...form, pick: { job_ids: [] } })).toEqual({ kind: "percent", value: 5, round: "dollar", jobs: { job_ids: [] } });
    expect(priceChangeOf({ ...form, lineServiceId: "", pick: {} })).toEqual({ kind: "percent", value: 5, round: "dollar" });
  });

  it("says what's wrong before the database is asked, in its words", () => {
    expect(priceChangeOf({ ...form, amount: "" })).toBe("Enter how much to change prices by.");
    expect(priceChangeOf({ ...form, amount: "0" })).toBe("Enter how much to change prices by.");
    expect(priceChangeOf({ ...form, amount: "1.2.3" })).toBe("Enter how much to change prices by.");
    expect(priceChangeOf({ ...form, amount: "501" })).toBe("Enter a percentage up to 500, or down by less than 100.");
    expect(priceChangeOf({ ...form, direction: "down", amount: "100" })).toBe("Enter a percentage up to 500, or down by less than 100.");
    expect(priceChangeOf({ ...form, direction: "down", amount: "99.9" })).toMatchObject({ value: -99.9 });
    expect(priceChangeOf({ ...form, kind: "amount", amount: "100001" })).toBe("That amount is too large.");
  });
});

describe("sending a preview to be applied", () => {
  const jobs = [job(1), job(2, { lines: [{ line_id: "l2a", name: "Mowing", quantity: 1, unit: "visit", old_price: 45, new_price: 47.25 }, { line_id: "l2b", name: "Edging", quantity: 2, unit: "visit", old_price: 10, new_price: 10.5 }] }), job(3)];

  it("goes a group of whole jobs at a time, each line with the old and new price that were shown", () => {
    const groups = priceChangeGroups(jobs, null, 2);
    expect(groups.map((g) => g.jobs)).toEqual([2, 1]);
    expect(groups[0]!.lines).toEqual([
      { line_id: "l1", old_price: 45, new_price: 47.25 },
      { line_id: "l2a", old_price: 45, new_price: 47.25 },
      { line_id: "l2b", old_price: 10, new_price: 10.5 },
    ]);
    expect(groups[1]!.lines.map((l) => l.line_id)).toEqual(["l3"]);
  });

  it("never splits a job's lines between groups", () => {
    for (const size of [1, 2, 3]) {
      for (const group of priceChangeGroups(jobs, null, size)) {
        const ids = group.lines.map((l) => l.line_id);
        expect(ids.includes("l2a")).toBe(ids.includes("l2b"));
      }
    }
  });

  it("leaves out the jobs unticked in the preview", () => {
    expect(priceChangeGroups(jobs, new Set(["j1", "j3"])).flatMap((g) => g.lines.map((l) => l.line_id))).toEqual(["l1", "l3"]);
    expect(priceChangeGroups(jobs, new Set())).toEqual([]);
  });

  it("is a hundred jobs a call unless told otherwise", () => {
    expect(priceChangeGroups(Array.from({ length: 250 }, (_, i) => job(i))).map((g) => g.jobs)).toEqual([100, 100, 50]);
  });
});

describe("what a preview comes to", () => {
  const jobs = [job(1), job(2, { old_price: 200, new_price: 210, pricing: "fixed", schedule: "monthly", autopay: true }), job(3, { autopay: true, over_limit: true }), job(4, { autopay: true, over_limit: true, was_over_limit: true })];

  it("the jobs ticked, their lines and their prices before and after", () => {
    expect(priceChangeTotals(jobs)).toEqual({ jobs: 4, lines: 4, old_price: 335, new_price: 351.75, autopay: 3, over_limit: 1 });
    expect(priceChangeTotals(jobs, new Set(["j1", "j2"]))).toEqual({ jobs: 2, lines: 2, old_price: 245, new_price: 257.25, autopay: 1, over_limit: 0 });
  });

  it("a job's price is for a visit, a month, or each invoice of a fixed price billed as needed", () => {
    expect(priceIsFor(jobs[0]!)).toBe("a visit");
    expect(priceIsFor(jobs[1]!)).toBe("a month");
    expect(priceIsFor({ pricing: "fixed", schedule: "as_needed" })).toBe("an invoice");
    expect(priceIsFor({ pricing: "per_visit", schedule: "monthly" })).toBe("a visit");
  });
});

describe("what the preview says about autopay", () => {
  it("nothing when no job is on it", () => {
    expect(autopayNote({ autopay: 0, over_limit: 0 }, 500, money)).toBeNull();
  });

  it("that nobody is asked to agree again, and the card is charged the new price", () => {
    expect(autopayNote({ autopay: 1, over_limit: 0 }, 500, money)).toBe("1 of these jobs is on autopay. Their clients aren't asked to agree again: the saved card is charged the new price from the next invoice.");
    expect(autopayNote({ autopay: 12, over_limit: 0 }, null, money)).toBe("12 of these jobs are on autopay. Their clients aren't asked to agree again: the saved card is charged the new price from the next invoice.");
  });

  it("and which charges would wait for the office's OK, by the company's limit", () => {
    expect(autopayNote({ autopay: 12, over_limit: 1 }, 500, money)).toBe(
      "12 of these jobs are on autopay. Their clients aren't asked to agree again: the saved card is charged the new price from the next invoice. 1 would go over your $500 autopay limit, so that charge waits for your OK each time. A client who pays from a bank account is sent the invoice to pay instead.",
    );
    expect(autopayNote({ autopay: 12, over_limit: 3 }, 500, money)).toContain("3 would go over your $500 autopay limit, so those charges wait for your OK each time. A client who pays from a bank account is sent the invoice to pay instead.");
  });
});

describe("the preview as a CSV", () => {
  it("has a row for each line changed, with its job and the job's price before and after", () => {
    const rows = priceChangeRows([job(7, { autopay: true }), job(8, { pricing: "fixed", schedule: "monthly", old_price: 200, new_price: 210, autopay: true, over_limit: true })], new Set(["j7", "j8"]));
    expect(rows).toEqual([
      { job: 7, title: "Mow 7", client: "Client 7", line: "Mowing", quantity: 1, old_price: "45.00", new_price: "47.25", job_price_for: "a visit", job_old_price: "45.00", job_new_price: "47.25", autopay: "Yes" },
      { job: 8, title: "Mow 8", client: "Client 8", line: "Mowing", quantity: 1, old_price: "45.00", new_price: "47.25", job_price_for: "a month", job_old_price: "200.00", job_new_price: "210.00", autopay: "Yes, over the limit" },
    ]);
    expect(Object.keys(rows[0]!)).toEqual(PRICE_CHANGE_COLUMNS.map((c) => c.key));
    expect(priceChangeRows([job(7)], new Set())).toEqual([]);
  });
});
