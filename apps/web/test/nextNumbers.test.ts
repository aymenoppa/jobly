/**
 * Settings → Company's next numbers (features/settings/nextNumbers.ts): what the form refuses before
 * it saves, in the words the database refuses it with (public.set_next_number, tested in
 * supabase/tests/next_numbers_test.sql), and which numbers it saves.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { changedNumbers, nextNumberProblem, NUMBER_KINDS } from "../src/features/settings/nextNumbers";

const saved = [
  { kind: "request", next_number: 51, highest_used: 50 },
  { kind: "quote", next_number: 1, highest_used: 0 },
  { kind: "job", next_number: 901, highest_used: 900 },
  { kind: "invoice", next_number: 4312, highest_used: 4311 },
];

describe("a next number as typed", () => {
  it("is fine above the highest number used, up or back down", () => {
    expect(nextNumberProblem("invoice", "4312", 4311)).toBeNull();
    expect(nextNumberProblem("invoice", " 50000 ", 4311)).toBeNull();
    expect(nextNumberProblem("quote", "1", 0)).toBeNull();
    expect(nextNumberProblem("job", "999999999", 900)).toBeNull();
  });

  it("is refused at or below a number already used, saying which and what the lowest is", () => {
    expect(nextNumberProblem("invoice", "4311", 4311)).toBe("Invoice #4311 is already used, so the next number has to be 4312 or higher. Two invoices can't share a number.");
    expect(nextNumberProblem("job", "7", 900)).toBe("Job #900 is already used, so the next number has to be 901 or higher. Two jobs can't share a number.");
  });

  it("has to be a whole number from 1 to 999,999,999", () => {
    for (const typed of ["", "0", "-4", "12.5", "1e3", "abc", "1000000000"]) expect(nextNumberProblem("quote", typed, 0), typed).toBe("Enter a whole number from 1 to 999,999,999.");
  });

  it("says the same as the database does", () => {
    const sql = readFileSync(fileURLToPath(new URL("../../../supabase/migrations/20261113000130_next_numbers.sql", import.meta.url)), "utf8");
    expect(sql).toContain("'% #% is already used, so the next number has to be % or higher. Two %s can''t share a number.'");
    expect(sql).toContain("'Enter a whole number from 1 to 999,999,999'");
    for (const { kind } of NUMBER_KINDS) expect(sql).toContain(`when '${kind}' then '${kind}s'`);
  });
});

describe("the numbers to save", () => {
  it("are only the ones typed that differ from what's saved, in the order work goes", () => {
    expect(changedNumbers(saved, {})).toEqual([]);
    expect(changedNumbers(saved, { invoice: "4312", job: "901" })).toEqual([]);
    expect(changedNumbers(saved, { invoice: "5000", quote: "2000", job: " 901 " })).toEqual([{ kind: "quote", next: 2000 }, { kind: "invoice", next: 5000 }]);
  });

  it("leave a field that was cleared as it was", () => {
    expect(changedNumbers(saved, { invoice: "" })).toEqual([]);
  });
});
