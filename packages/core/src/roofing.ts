/**
 * Roofing values for quote formulas, from a roof measured on the map: its surface (each section at
 * its own pitch, else the drawing's), the squares that come to with and without waste, and how much
 * of it is steep enough for a steep charge. The roof edges (eave_ft and the rest) come from
 * edgeLengths in geo.ts. Used by quote formulas like any other measurement value (FORMULA_VARIABLES).
 */
import { edgeLengths, pitchFactor, pitchSlope, roofAreaSqft, ROOF_EDGES, SQFT_PER_ROOFING_SQUARE, type Feature, type FeatureCollection, type RoofEdge, type Section } from "./geo";

/** Rise per 12: from here up, most crews need roof jacks and charge a steep fee. */
export const STEEP_RISE = 8;

/** Roof edges on the map, in the legend and on the roof report. Bright enough to read on shingles. */
export const ROOF_EDGE_COLORS: Record<RoofEdge, string> = {
  eave: "#38bdf8",
  rake: "#a3e635",
  ridge: "#f43f5e",
  hip: "#f59e0b",
  valley: "#c084fc",
};

/**
 * Values a roof measurement gives formulas, with what each one means for the Price list's help and
 * assistants.
 */
export const ROOFING_VARIABLES = {
  roof_sqft: "Roof surface, sq ft (each section at its pitch, before waste)",
  squares: "Roofing squares with waste (100 sq ft of roof each)",
  roof_squares: "Roofing squares without waste, for tear-off and labor",
  steep_squares: `Squares (without waste) on sections at ${STEEP_RISE}/12 or steeper`,
} as const;
export type RoofingVariable = keyof typeof ROOFING_VARIABLES;
export const ROOFING_VARIABLE_NAMES = Object.keys(ROOFING_VARIABLES) as RoofingVariable[];

/** Made-up values for checking a formula that uses roofing values (Settings → Price list). */
export const ROOFING_SAMPLE: Record<RoofingVariable, number> = { roof_sqft: 2800, squares: 30.8, roof_squares: 28, steep_squares: 6 };

const round2 = (n: number) => Math.round(n * 100) / 100;
const ownPitch = (s: Section, pitch: string | null | undefined) => (typeof s.pitch === "string" && s.pitch.trim() ? s.pitch : pitch);

/**
 * Each roofing value for a saved or live drawing (its sections, as summarizeFeatureCollection makes
 * them). A drawing with no pitch counts as flat. Throws RangeError for a pitch that doesn't read.
 */
export function roofingQuantities(sections: readonly Section[], pitch: string | null | undefined, wastePct: number): Record<RoofingVariable, number> {
  const surface = roofAreaSqft({ sections: [...sections] }, pitch);
  const steep = sections.reduce((sum, s) => {
    if (s.kind !== "Area") return sum;
    const at = ownPitch(s, pitch);
    return pitchSlope(at) * 12 >= STEEP_RISE - 1e-9 ? sum + Number(s.value) * pitchFactor(at) : sum;
  }, 0);
  const waste = 1 + (Number(wastePct) || 0) / 100;
  return {
    roof_sqft: round2(surface),
    squares: round2((surface * waste) / SQFT_PER_ROOFING_SQUARE),
    roof_squares: round2(surface / SQFT_PER_ROOFING_SQUARE),
    steep_squares: round2(steep / SQFT_PER_ROOFING_SQUARE),
  };
}

/** roofingQuantities for a saved drawing, or nulls when a pitch doesn't read (formulas that use them say so). */
export function savedRoofingQuantities(sections: readonly Section[], pitch: string | null | undefined, wastePct: number): Record<RoofingVariable, number | null> {
  try {
    return roofingQuantities(sections, pitch, wastePct);
  } catch {
    return Object.fromEntries(ROOFING_VARIABLE_NAMES.map((name) => [name, null])) as Record<RoofingVariable, null>;
  }
}

/** The waste % to start a roof on: about 10% for plain gables, 15% once it has hips or valleys. */
export function suggestedWaste(edges: Partial<Record<RoofEdge, number>>): number {
  return (edges.hip ?? 0) > 0 || (edges.valley ?? 0) > 0 ? 15 : 10;
}

/** Whether a drawing is a roof: a pitch on it somewhere, or lines marked as roof edges. */
export function isRoofDrawing(sections: readonly Pick<Section, "kind" | "pitch" | "edge">[], pitch?: string | null): boolean {
  return Boolean(pitch?.trim()) || sections.some((s) => (s.kind === "Area" && Boolean(s.pitch?.trim())) || (s.kind === "Length" && (ROOF_EDGES as readonly unknown[]).includes(s.edge)));
}

// ---------------------------------------------------------------------------------------------
// A roof measured by someone else's report (EagleView, Hover): typed in, not drawn
// ---------------------------------------------------------------------------------------------

/** measurements.provider for a roof typed in from a report, where a drawn one names its aerial imagery. */
export const REPORT_PROVIDER = "report";
export const REPORT_TITLE = "Roof measurements from a report";
/** Whether a measurement was typed in from a report rather than drawn. */
export const isReportRoof = (m: { provider?: string | null } | null | undefined) => m?.provider === REPORT_PROVIDER;

/** What a roof report says, as it's typed in. */
export interface RoofReport {
  /** Squares of roof surface before waste: the report's total roof area over 100. */
  squares: number;
  /** The predominant pitch: "6/12", or just its rise ("6"). */
  pitch: string;
  eave_ft: number;
  rake_ft: number;
  ridge_ft: number;
  hip_ft: number;
  valley_ft: number;
  waste_pct: number;
}

const REPORT_EDGES: Record<RoofEdge, { field: keyof RoofReport; label: string }> = {
  eave: { field: "eave_ft", label: "Eaves" },
  rake: { field: "rake_ft", label: "Rakes" },
  ridge: { field: "ridge_ft", label: "Ridges" },
  hip: { field: "hip_ft", label: "Hips" },
  valley: { field: "valley_ft", label: "Valleys" },
};
const REPORT_ROOF = "Roof (from a report)";

/** A pitch as typed on a report: "6" is 6/12. Blank stays blank. */
export const reportPitch = (pitch: string) => (/^\s*\d+(\.\d+)?\s*$/.test(pitch) ? `${pitch.trim()}/12` : pitch.trim());

/** Why a report's numbers can't be saved, in words for the form; null when they can. */
export function roofReportProblem(report: RoofReport): string | null {
  if (!(report.squares > 0 && report.squares <= 100_000)) return "Enter the roof's size in squares or square feet.";
  if (!reportPitch(report.pitch)) return "Enter the predominant pitch, like 6/12. A flat roof is 0/12.";
  try {
    pitchSlope(reportPitch(report.pitch));
  } catch {
    return "That pitch doesn't read. Write it like 6/12.";
  }
  for (const edge of ROOF_EDGES) {
    const feet = Number(report[REPORT_EDGES[edge].field]);
    if (!(feet >= 0 && feet <= 1_000_000)) return `${REPORT_EDGES[edge].label} are a length in feet, or 0.`;
  }
  if (!(report.waste_pct >= 0 && report.waste_pct <= 100)) return "Waste is 0 to 100%.";
  return null;
}

/**
 * A report's numbers as a drawing, so everything that reads a drawn roof reads this one the same
 * way: the roof packages, the formulas' values (ROOFING_VARIABLES and the edges) and the estimate.
 * One area carries the roof at the predominant pitch, and one line for each kind of edge carries
 * its feet, each as a measured value (manual_value in summarizeFeatureCollection), which stands in
 * for what the shape itself would measure. The shapes are placeholders a few feet across at the
 * property (`at`): nothing was traced. The area is the roof seen from above (its surface over the
 * pitch's slope factor), since a drawing's area is what the map sees and its pitch makes the surface.
 * Save it with provider REPORT_PROVIDER. Throws RangeError for a pitch that doesn't read.
 */
export function roofReportCollection(report: RoofReport, at?: { lat: number; lng: number } | null): FeatureCollection {
  const pitch = reportPitch(report.pitch);
  const plan = Math.round(((report.squares * SQFT_PER_ROOFING_SQUARE) / pitchFactor(pitch)) * 100) / 100;
  const [lng, lat] = [at?.lng ?? 0, at?.lat ?? 0];
  // About a yard: enough to be a shape, too small to be taken for the roof.
  const d = 0.00001;
  const features: Feature[] = [
    {
      type: "Feature",
      id: "report-roof",
      geometry: { type: "Polygon", coordinates: [[[lng, lat], [lng + d, lat], [lng + d, lat + d], [lng, lat + d], [lng, lat]]] },
      properties: { label: REPORT_ROOF, pitch, manual_value: plan },
    },
  ];
  ROOF_EDGES.forEach((edge, i) => {
    const feet = Math.round(Number(report[REPORT_EDGES[edge].field]) * 100) / 100;
    if (!(feet > 0)) return;
    const y = lat + d * (i + 2);
    features.push({ type: "Feature", id: `report-${edge}`, geometry: { type: "LineString", coordinates: [[lng, y], [lng + d, y]] }, properties: { label: REPORT_EDGES[edge].label, edge, pitch, manual_value: feet } });
  });
  return { type: "FeatureCollection", features };
}

/** A saved report's numbers back from its measurement, to change them. */
export function roofReportOf(m: { sections: unknown; roof_pitch: string | null; waste_pct: number | string | null }): RoofReport {
  const sections = (Array.isArray(m.sections) ? m.sections : []) as Section[];
  const edges = edgeLengths({ sections });
  const pitch = sections.find((s) => s.kind === "Area" && s.pitch)?.pitch ?? m.roof_pitch ?? "";
  const values = savedRoofingQuantities(sections, m.roof_pitch, 0);
  return { squares: values.roof_squares ?? 0, pitch, eave_ft: edges.eave, rake_ft: edges.rake, ridge_ft: edges.ridge, hip_ft: edges.hip, valley_ft: edges.valley, waste_pct: Number(m.waste_pct) || 0 };
}

// ---------------------------------------------------------------------------------------------
// Before a roof estimate goes out (Roofing → Send): what its packages left off, and low slopes
// ---------------------------------------------------------------------------------------------

/** Below this rise per 12, shingles need low-slope underlayment (ice and water shield over the section). */
export const LOW_SLOPE_RISE = 4;
/** Below this rise per 12, shingles don't go on at all: the section is another system (modified bitumen, TPO). */
export const SHINGLE_MIN_RISE = 2;

/** A roof section too low for shingles as they are: under 4/12, or under 2/12 (`tooLow`). */
export interface LowSlopeSection {
  label: string;
  pitch: string;
  tooLow: boolean;
}

/** The roof's sections under 4/12, for a shingle roof. Sections with no pitch, or one that doesn't read, aren't judged. */
export function lowSlopeSections(sections: readonly Pick<Section, "kind" | "label" | "pitch">[], pitch: string | null | undefined): LowSlopeSection[] {
  return sections.flatMap((s) => {
    if (s.kind !== "Area") return [];
    const at = ownPitch(s as Section, pitch);
    if (!at?.trim()) return [];
    let rise: number;
    try {
      rise = pitchSlope(at) * 12;
    } catch {
      return [];
    }
    return rise < LOW_SLOPE_RISE - 1e-9 ? [{ label: s.label, pitch: rise === 0 ? "flat" : at, tooLow: rise < SHINGLE_MIN_RISE - 1e-9 }] : [];
  });
}

const EDGE_PLURALS: Record<RoofEdge, string> = { eave: "eaves", rake: "rakes", ridge: "ridges", hip: "hips", valley: "valleys" };

/**
 * Why a package line left off a roof estimate needs someone to decide before it goes out: it
 * couldn't be worked out (`reason`), or it came to nothing (`none`) from roof edges none of which
 * are marked ("No eaves or rakes marked on the roof"). Null for one that's simply none on this roof,
 * like a steep charge on a 6/12: there's nothing missing to decide about. `reads` is what its
 * formula reads (core formulaVariables).
 */
export function leftOutReason(reads: ReadonlySet<string>, none: boolean, reason: string): string | null {
  if (!none) return reason;
  const edges = ROOF_EDGES.filter((e) => reads.has(`${e}_ft`));
  if (!edges.length) return null;
  const words = edges.map((e) => EDGE_PLURALS[e]);
  return `No ${words.length < 3 ? words.join(" or ") : `${words.slice(0, -1).join(", ")} or ${words.at(-1)}`} marked on the roof`;
}
