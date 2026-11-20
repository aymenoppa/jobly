/**
 * Extra work on one visit of a repeating job, on the office's screens (features/jobs/VisitExtras.tsx):
 * what a typed extra needs before it's saved, how one reads in a list, and where the editor shows.
 * The billing rules are the database's (supabase/tests/visit_extras_test.sql).
 */
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { extrasKey, extraText, readExtraDraft } from "../src/features/jobs/VisitExtras";

const source = (file: string) => readFileSync(fileURLToPath(new URL(file, import.meta.url)), "utf8");

describe("typing an extra", () => {
  it("takes what it is, how many and a price, rounded as the database keeps them", () => {
    expect(readExtraDraft({ name: "  Mulch ", quantity: "2.5", price: "60" })).toEqual({ name: "Mulch", quantity: 2.5, unit_price: 60 });
    expect(readExtraDraft({ name: "Edging", quantity: "0.3335", price: "10.005" })).toEqual({ name: "Edging", quantity: 0.334, unit_price: 10.01 });
    expect(readExtraDraft({ name: "No charge", quantity: "1", price: "0" })).toEqual({ name: "No charge", quantity: 1, unit_price: 0 });
  });

  it("says what's missing", () => {
    expect(readExtraDraft({ name: " ", quantity: "1", price: "5" })).toBe("Say what the extra work is.");
    expect(readExtraDraft({ name: "Mulch", quantity: "0", price: "5" })).toBe("Enter how many.");
    expect(readExtraDraft({ name: "Mulch", quantity: "", price: "5" })).toBe("Enter how many.");
    expect(readExtraDraft({ name: "Mulch", quantity: "200000", price: "5" })).toBe("Enter how many.");
    expect(readExtraDraft({ name: "Mulch", quantity: "1", price: "" })).toBe("Enter the price.");
    expect(readExtraDraft({ name: "Mulch", quantity: "1", price: "1.2.3" })).toBe("Enter the price.");
  });
});

describe("an extra in a list", () => {
  it("reads as what, how many and what it comes to", () => {
    expect(extraText({ name: "Mulch", quantity: 2, unit: "yd", unit_price: 60 })).toBe("Mulch · 2 yd · $120.00");
    expect(extraText({ name: "Aeration", quantity: 1, unit: "ea", unit_price: 80 })).toBe("Aeration · $80.00");
    expect(extraText({ name: "Edging", quantity: 0.333, unit: "hr", unit_price: 10 })).toBe("Edging · 0.333 hr · $3.33");
  });
});

describe("where the office adds extra work", () => {
  it("in the schedule's visit dialog, for a visit that exists and is for a job", () => {
    expect(source("../src/features/schedule/VisitDialog.tsx")).toContain('{visit.id && visit.job_id && (visit.kind ?? "job") === "job" && <VisitExtrasEditor visitId={visit.id} jobId={visit.job_id} onChanged={onSaved} />}');
  });

  it("and on the job page, under each visit that can take it, with what wasn't billed and what the crew added", () => {
    const page = source("../src/features/jobs/JobPage.tsx");
    expect(page).toContain("{addsExtras && v.kind === \"job\" && visitTakesExtras(v) && (");
    expect(page).toContain("<VisitExtraLines extras={visitExtras.get(v.id) ?? []} visit={v} />");
    expect(page).toContain("<ExtrasToReview jobId={j.id} extras={extras.data} visits={visits} />");
  });

  it("never keeps them on a phone: they carry prices (lib/offline.ts keeps only a job's list of work)", () => {
    expect(extrasKey("j1")).toEqual(["job", "j1", "extras"]);
    expect(source("../src/lib/offline.ts")).toContain('!(q.queryKey[0] === "job" && q.queryKey[2] !== "scope")');
  });

  it("the editor has no form of its own, so adding one never saves the dialog it sits in", () => {
    expect(source("../src/features/jobs/VisitExtras.tsx")).not.toMatch(/<form\b/);
  });
});
