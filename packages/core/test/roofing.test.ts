import { describe, expect, it } from "vitest";
import {
  evaluateFormula,
  FORMULA_VARIABLES,
  formulaVariables,
  isRoofDrawing,
  leftOutReason,
  lowSlopeSections,
  optionLabels,
  PRESETS,
  ROOFING_SAMPLE,
  ROOFING_VARIABLE_NAMES,
  roofingQuantities,
  savedRoofingQuantities,
  suggestedWaste,
  drawingSquares,
  edgeLengths,
  isReportRoof,
  pitchProblem,
  REPORT_PROVIDER,
  reportPitch,
  roofReportCollection,
  roofReportOf,
  roofReportProblem,
  summarizeFeatureCollection,
  type RoofReport,
  type Section,
} from "../src";

const area = (value: number, pitch?: string): Section => ({ feature_id: `a${value}`, label: "Roof", kind: "Area", value, unit: "sq ft", manual_override: false, pitch });
const line = (value: number, edge?: Section["edge"]): Section => ({ feature_id: `l${value}`, label: "Line", kind: "Length", value, unit: "ft", manual_override: false, edge });

describe("roofing values", () => {
  it("gives formulas a value for each, with sample values for the price list", () => {
    for (const name of ROOFING_VARIABLE_NAMES) expect(FORMULA_VARIABLES).toContain(name);
    expect(Object.keys(ROOFING_SAMPLE).sort()).toEqual([...ROOFING_VARIABLE_NAMES].sort());
  });

  it("works out the roof at each section's pitch, with and without waste", () => {
    // 2,000 sq ft from above at 6/12 (×1.118) and a 400 sq ft porch at 3/12 (×1.031), 10% waste.
    const q = roofingQuantities([area(2000), area(400, "3/12"), line(80, "eave")], "6/12", 10);
    const surface = 2000 * Math.sqrt(1 + 0.25) + 400 * Math.sqrt(1 + 0.0625);
    expect(q.roof_sqft).toBeCloseTo(surface, 1);
    expect(q.roof_squares).toBeCloseTo(surface / 100, 2);
    expect(q.squares).toBeCloseTo((surface * 1.1) / 100, 2);
    expect(q.steep_squares).toBe(0);
  });

  it("counts the steep sections (8/12 and up) for a steep charge", () => {
    const q = roofingQuantities([area(1000, "8/12"), area(1000, "7/12"), area(500, "12/12")], null, 15);
    expect(q.steep_squares).toBeCloseTo((1000 * Math.sqrt(1 + (8 / 12) ** 2) + 500 * Math.SQRT2) / 100, 2);
    // Waste goes on what's ordered, not on the steep charge.
    expect(q.squares).toBeCloseTo(q.roof_squares * 1.15, 1);
  });

  it("counts a roof with no pitch as flat, and leaves the values blank for one that doesn't read", () => {
    expect(roofingQuantities([area(1500)], "", 0)).toEqual({ roof_sqft: 1500, squares: 15, roof_squares: 15, steep_squares: 0 });
    expect(() => roofingQuantities([area(1500)], "steep", 0)).toThrow(RangeError);
    expect(savedRoofingQuantities([area(1500)], "steep", 0)).toEqual({ roof_sqft: null, squares: null, roof_squares: null, steep_squares: null });
  });

  it("tells a roof from other drawings", () => {
    expect(isRoofDrawing([area(1000)], null)).toBe(false);
    expect(isRoofDrawing([area(1000)], "5/12")).toBe(true);
    expect(isRoofDrawing([area(1000, "4/12")])).toBe(true);
    expect(isRoofDrawing([line(40, "ridge")])).toBe(true);
    expect(isRoofDrawing([line(40)])).toBe(false);
  });

  it("starts the waste at 10%, or 15% with hips or valleys", () => {
    expect(suggestedWaste({ eave: 80, rake: 60, ridge: 40 })).toBe(10);
    expect(suggestedWaste({ eave: 80, hip: 30 })).toBe(15);
    expect(suggestedWaste({ valley: 12 })).toBe(15);
  });

  it("gives the roofing price list a value for every service it measures", () => {
    const roofing = PRESETS.roofing_exteriors;
    const formulas = new Map(roofing.formulas.map((f) => [f.name, f.formula]));
    const sample = { ...ROOFING_SAMPLE, area_sqft: 2500, length_ft: 300, pitch_factor: 1.12, waste: 0.1, eave_ft: 120, rake_ft: 80, ridge_ft: 40, hip_ft: 20, valley_ft: 20 };
    for (const s of roofing.services.filter((s) => s.formula_name)) {
      expect(evaluateFormula(formulas.get(s.formula_name!)!, sample), s.name).toBeGreaterThan(0);
    }
  });
});

describe("Good, Better and Best", () => {
  const roof = (id: string, unit_price: number, option_group: string | null = "Roof") => ({ id, optional: true, option_group, quantity: 30, unit_price });

  it("names the choices in a group from the cheapest up", () => {
    const labels = optionLabels([roof("metal", 1285), roof("arch", 560), roof("designer", 735), { id: "gutters", optional: false, quantity: 120, unit_price: 12 }]);
    expect(Object.fromEntries(labels)).toEqual({ arch: "Good", designer: "Better", metal: "Best" });
  });

  it("names two choices Good and Better, and leaves one, four or ungrouped options alone", () => {
    expect(Object.fromEntries(optionLabels([roof("a", 500), roof("b", 700)]))).toEqual({ a: "Good", b: "Better" });
    expect(optionLabels([roof("a", 500)]).size).toBe(0);
    expect(optionLabels([roof("a", 1), roof("b", 2), roof("c", 3), roof("d", 4)]).size).toBe(0);
    expect(optionLabels([roof("a", 500, null), roof("b", 700, null)]).size).toBe(0);
  });
});

describe("before a roof estimate goes out", () => {
  it("finds the sections too low for shingles", () => {
    const main = { ...area(1800, "6/12"), label: "Main roof" };
    const porch = { ...area(200, "3.5/12"), label: "Porch" };
    const deck = { ...area(120, "1.5/12"), label: "Back deck" };
    const flat = { ...area(80, "0/12"), label: "Garage" };
    expect(lowSlopeSections([main, porch, deck, flat, line(40, "eave")], null)).toEqual([
      { label: "Porch", pitch: "3.5/12", tooLow: false },
      { label: "Back deck", pitch: "1.5/12", tooLow: true },
      { label: "Garage", pitch: "flat", tooLow: true },
    ]);
    // A section without its own pitch is at the drawing's; with none at all, or one that doesn't read, it isn't judged.
    expect(lowSlopeSections([area(500)], "3/12")).toEqual([{ label: "Roof", pitch: "3/12", tooLow: false }]);
    expect(lowSlopeSections([area(500), area(600, "steep?")], null)).toEqual([]);
    expect(lowSlopeSections([area(500, "4/12")], null)).toEqual([]);
  });

  it("asks about what's missing, not what's simply none on this roof", () => {
    expect(leftOutReason(formulaVariables("(eave_ft + rake_ft) / 10"), true, "None on this roof")).toBe("No eaves or rakes marked on the roof");
    expect(leftOutReason(formulaVariables("valley_ft / 10"), true, "None on this roof")).toBe("No valleys marked on the roof");
    expect(leftOutReason(formulaVariables("(ridge_ft + hip_ft + valley_ft) / 33"), true, "None on this roof")).toBe("No ridges, hips or valleys marked on the roof");
    expect(leftOutReason(formulaVariables("steep_squares"), true, "None on this roof")).toBeNull();
    expect(leftOutReason(formulaVariables("squares"), false, "The roof hasn't been measured yet")).toBe("The roof hasn't been measured yet");
  });
});

describe("a roof typed in from a report", () => {
  // An EagleView for a hip roof: 28.5 squares at 6/12, with its edges, ordered with 12% waste.
  const report: RoofReport = { squares: 28.5, pitch: "6/12", eave_ft: 186, rake_ft: 0, ridge_ft: 42.5, hip_ft: 96, valley_ft: 38, waste_pct: 12 };
  const saved = (r: RoofReport, at?: { lat: number; lng: number }) => summarizeFeatureCollection(roofReportCollection(r, at), { pitch: reportPitch(r.pitch) });

  it("gives formulas and packages the report's own numbers, the way a drawn roof gives its", () => {
    const summary = saved(report, { lat: 37.13, lng: -80.41 });
    // Squares with and without waste, as the roofing variables give them.
    expect(roofingQuantities(summary.sections, "6/12", 12)).toEqual({ roof_sqft: 2850, squares: 31.92, roof_squares: 28.5, steep_squares: 0 });
    // Edges as typed: a report's lengths are the real ones, so the pitch doesn't stretch them again.
    expect(edgeLengths(summary)).toEqual({ eave: 186, rake: 0, ridge: 42.5, hip: 96, valley: 38 });
    // What the measurement keeps: squares to order, and it's a roof.
    expect(drawingSquares(summary, "6/12", 12)).toBeCloseTo(31.92, 2);
    expect(pitchProblem(summary, "6/12")).toBeNull();
    expect(isRoofDrawing(summary.sections, "6/12")).toBe(true);
    // The same formulas a drawn roof prices from.
    const vars = { ...roofingQuantities(summary.sections, "6/12", 12), eave_ft: 186, rake_ft: 0, ridge_ft: 42.5, hip_ft: 96, valley_ft: 38 };
    expect(evaluateFormula("eave_ft + rake_ft", vars)).toBe(186);
    expect(evaluateFormula("ridge_ft + hip_ft", vars)).toBe(138.5);
    // Said for what it is wherever its shapes are named, and no bigger than a placeholder on the map.
    expect(summary.sections.map((s) => [s.label, s.kind, s.manual_override])).toEqual([["Roof (from a report)", "Area", true], ["Eaves", "Length", true], ["Ridges", "Length", true], ["Hips", "Length", true], ["Valleys", "Length", true]]);
    expect(isReportRoof({ provider: REPORT_PROVIDER })).toBe(true);
    expect(isReportRoof({ provider: "naip" })).toBe(false);
  });

  it("counts a steep roof as steep, a flat one as flat, and a pitch typed as its rise", () => {
    expect(roofingQuantities(saved({ ...report, pitch: "10" }).sections, "10/12", 0)).toMatchObject({ roof_squares: 28.5, steep_squares: 28.5 });
    expect(roofingQuantities(saved({ ...report, pitch: "0/12" }).sections, "0/12", 0)).toMatchObject({ roof_sqft: 2850, steep_squares: 0 });
    expect(reportPitch(" 6 ")).toBe("6/12");
    expect(reportPitch("6/12")).toBe("6/12");
    expect(reportPitch("")).toBe("");
  });

  it("reads its numbers back, to change them", () => {
    const summary = saved(report);
    expect(roofReportOf({ sections: summary.sections, roof_pitch: "6/12", waste_pct: "12" })).toEqual(report);
    expect(roofReportOf({ sections: null, roof_pitch: null, waste_pct: null })).toMatchObject({ squares: 0, pitch: "", eave_ft: 0, waste_pct: 0 });
  });

  it("says what's wrong with numbers that can't be a roof", () => {
    expect(roofReportProblem(report)).toBeNull();
    expect(roofReportProblem({ ...report, squares: 0 })).toBe("Enter the roof's size in squares or square feet.");
    expect(roofReportProblem({ ...report, squares: Number.NaN })).toBe("Enter the roof's size in squares or square feet.");
    expect(roofReportProblem({ ...report, pitch: " " })).toBe("Enter the predominant pitch, like 6/12. A flat roof is 0/12.");
    expect(roofReportProblem({ ...report, pitch: "steep" })).toBe("That pitch doesn't read. Write it like 6/12.");
    expect(roofReportProblem({ ...report, hip_ft: -4 })).toBe("Hips are a length in feet, or 0.");
    expect(roofReportProblem({ ...report, waste_pct: 140 })).toBe("Waste is 0 to 100%.");
  });
});
