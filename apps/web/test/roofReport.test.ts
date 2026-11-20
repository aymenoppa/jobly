/**
 * Roofing → a project's first step → "Enter measurements from a report" (features/roofing/flow/
 * RoofReport.tsx): what's typed becomes the report the measurement is made from (core
 * roofReportCollection, tested with the roofing values in packages/core/test/roofing.test.ts).
 */
import { describe, expect, it, vi } from "vitest";

vi.mock("../src/lib/api", () => ({ api: {}, supabase: () => ({}), unwrap: (r: { data: unknown }) => r.data }));
const { draftReport, reportDraft } = await import("../src/features/roofing/flow/RoofReport");

const EMPTY = { eave_ft: "", rake_ft: "", ridge_ft: "", hip_ft: "", valley_ft: "" };

describe("a roof report's numbers, as typed", () => {
  it("starts empty, in squares", () => {
    expect(reportDraft(null)).toEqual({ size: "", by: "squares", pitch: "", edges: EMPTY, waste: "" });
  });

  it("takes the size in squares or in square feet", () => {
    const typed = { ...reportDraft(null), size: "28.5", pitch: "6/12", edges: { ...EMPTY, eave_ft: "186", ridge_ft: "42.5" } };
    expect(draftReport(typed)).toEqual({ squares: 28.5, pitch: "6/12", eave_ft: 186, rake_ft: 0, ridge_ft: 42.5, hip_ft: 0, valley_ft: 0, waste_pct: 10 });
    expect(draftReport({ ...typed, size: "2850", by: "sqft" }).squares).toBe(28.5);
  });

  it("suggests 15% waste once the roof has hips or valleys, unless one is typed", () => {
    const hips = { ...reportDraft(null), size: "30", pitch: "8/12", edges: { ...EMPTY, hip_ft: "96" } };
    expect(draftReport(hips).waste_pct).toBe(15);
    expect(draftReport({ ...hips, waste: "12" }).waste_pct).toBe(12);
    expect(draftReport({ ...hips, waste: "0" }).waste_pct).toBe(0);
  });

  it("shows a saved report's numbers again, to change them", () => {
    const saved = { squares: 28.5, pitch: "6/12", eave_ft: 186, rake_ft: 0, ridge_ft: 42.5, hip_ft: 96, valley_ft: 38, waste_pct: 12 };
    const draft = reportDraft(saved);
    expect(draft).toEqual({ size: "28.5", by: "squares", pitch: "6/12", edges: { eave_ft: "186", rake_ft: "", ridge_ft: "42.5", hip_ft: "96", valley_ft: "38" }, waste: "12" });
    expect(draftReport(draft)).toEqual(saved);
  });
});
