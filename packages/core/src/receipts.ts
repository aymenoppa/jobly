/**
 * Receipts and supplier invoices read by Claude (apps/api/src/services/receipts.ts): what a reading
 * holds once it's been checked, whether its numbers add up, and which job and which of the job's
 * materials it seems to be for. The person adding the expense sees all of it filled in and decides;
 * nothing here saves anything.
 */
import { streetKey } from "./clientImport";

/** The categories an expense can have (the Add expense form's). */
export const EXPENSE_CATEGORIES = ["Materials", "Equipment rental", "Equipment upkeep", "Fuel", "Dump fees", "Subcontractor", "Permits", "Supplies", "Other"] as const;
export type ExpenseCategory = (typeof EXPENSE_CATEGORIES)[number];

/** One line of a supplier's invoice, as read. */
export interface ReceiptLine {
  description: string;
  quantity: number | null;
  unit: string | null;
  unit_price: number | null;
  /** The line's amount as printed, when it is. */
  amount: number | null;
}

/** What a receipt or supplier invoice says, once checked (services/receipts.ts parseReading). */
export interface ReceiptReading {
  kind: "receipt" | "supplier_invoice" | "other";
  vendor: string | null;
  /** YYYY-MM-DD. */
  date: string | null;
  invoice_number: string | null;
  subtotal: number | null;
  tax: number | null;
  total: number | null;
  category: ExpenseCategory | null;
  lines: ReceiptLine[];
  /** What on it might say which job it's for. */
  job_reference: { job_number: string | null; po_number: string | null; address: string | null };
}

/** The form's fields a reading fills in, by their names on the form. */
export type ReadField = "vendor" | "date" | "amount" | "tax" | "category" | "lines";

/** Which of the form's fields the reading had something for. */
export function readFields(r: ReceiptReading): ReadField[] {
  const out: ReadField[] = [];
  if (r.vendor) out.push("vendor");
  if (r.date) out.push("date");
  if (r.total !== null) out.push("amount");
  if (r.tax !== null) out.push("tax");
  if (r.category) out.push("category");
  if (r.lines.length) out.push("lines");
  return out;
}

const cents = (n: number) => Math.round(n * 100) / 100;
const money = (n: number) => `$${cents(n).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ",")}`;

/** A line's amount: as printed, or its quantity at its price. Null when neither is there. */
export const lineAmount = (l: ReceiptLine) => (l.amount !== null ? l.amount : l.quantity !== null && l.unit_price !== null ? cents(l.quantity * l.unit_price) : null);

/**
 * What doesn't add up, said plainly for the person checking it: a total missing, or lines and tax
 * that don't come to the total within two cents. A document that does add up has none.
 */
export function readingProblems(r: ReceiptReading): string[] {
  const out: string[] = [];
  if (r.total === null) return ["No total was found. Enter what it cost."];
  if (r.total <= 0) out.push("The total read isn't more than zero. Check it.");
  const tax = r.tax ?? 0;
  const amounts = r.lines.map(lineAmount);
  if (r.lines.length && amounts.every((a) => a !== null)) {
    const sum = cents(amounts.reduce((s, a) => s + a!, 0));
    if (Math.abs(sum + tax - r.total) > 0.02) out.push(`The lines${r.tax !== null ? " and tax" : ""} come to ${money(sum + tax)}, not the ${money(r.total)} total. Check them.`);
  } else if (r.subtotal !== null && Math.abs(r.subtotal + tax - r.total) > 0.02) {
    out.push(`The subtotal${r.tax !== null ? " and tax" : ""} come to ${money(r.subtotal + tax)}, not the ${money(r.total)} total. Check them.`);
  }
  if (r.lines.length && amounts.some((a) => a === null)) out.push("Some lines have no price. Check them.");
  return out;
}

// ---------------------------------------------------------------------------------------------
// Which job
// ---------------------------------------------------------------------------------------------

export interface JobCandidate {
  id: string;
  number: number | null;
  po_number?: string | null;
  property?: { line1: string | null } | null;
}

const squash = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, "");
/** The street part of an address as a key ("123 Main Street, Springfield" → "123mainst"), as client imports compare them. */
const streetOf = (address: string | null | undefined) => streetKey((address ?? "").split(/[,\n]/)[0]!);

/** The job number a reference names: "Job #1042", "J-1042", "1042". */
export function jobNumberOf(ref: string | null | undefined): number | null {
  const m = (ref ?? "").match(/(\d{1,9})/);
  return m ? Number(m[1]) : null;
}

/**
 * The job a receipt names, among the jobs the person can see: by its job number, else its PO number,
 * else the job's street address. Only when exactly one job fits; `why` says which.
 */
export function suggestJob(ref: ReceiptReading["job_reference"], jobs: readonly JobCandidate[]): { id: string; why: "job_number" | "po_number" | "address" } | null {
  const one = (fits: JobCandidate[]) => (fits.length === 1 ? fits[0]! : null);
  const number = jobNumberOf(ref.job_number);
  if (number !== null) {
    const hit = one(jobs.filter((j) => j.number === number));
    if (hit) return { id: hit.id, why: "job_number" };
  }
  const po = squash(ref.po_number ?? "");
  if (po) {
    const hit = one(jobs.filter((j) => j.po_number && squash(j.po_number) === po));
    if (hit) return { id: hit.id, why: "po_number" };
  }
  // A house number and a street, at least: "123main".
  const street = streetOf(ref.address);
  if (/^\d+[a-z]{3}/.test(street)) {
    const hit = one(jobs.filter((j) => {
      const theirs = streetOf(j.property?.line1);
      return /^\d+[a-z]{3}/.test(theirs) && (theirs === street || theirs.startsWith(street) || street.startsWith(theirs));
    }));
    if (hit) return { id: hit.id, why: "address" };
  }
  return null;
}

// ---------------------------------------------------------------------------------------------
// Which material
// ---------------------------------------------------------------------------------------------

const UNIT_NAMES: Record<string, string> = {
  ton: "ton", tons: "ton", tn: "ton", t: "ton",
  gal: "gal", gals: "gal", gallon: "gal", gallons: "gal",
  ea: "ea", each: "ea", pc: "ea", pcs: "ea", piece: "ea", pieces: "ea", unit: "ea", units: "ea",
  bag: "bag", bags: "bag",
  load: "load", loads: "load",
  yd3: "yd³", "yd³": "yd³", cy: "yd³", cuyd: "yd³", yard: "yd³", yards: "yd³", yd: "yd³", cubicyard: "yd³", cubicyards: "yd³",
  lf: "lf", linft: "lf", linearfeet: "lf", linearfoot: "lf",
  sqyd: "sq yd", sy: "sq yd", squareyard: "sq yd", squareyards: "sq yd",
  sqft: "sq ft", sf: "sq ft", squarefeet: "sq ft", squarefoot: "sq ft",
};
/** A unit to compare: "Tons" and "TN" are both "ton", "CY" is "yd³". Anything else, as it's written. */
export function unitKey(unit: string | null | undefined): string {
  const raw = (unit ?? "").trim().toLowerCase();
  const tight = raw.replace(/[\s.]/g, "");
  return UNIT_NAMES[tight] ?? raw;
}

const STOP = new Set(["the", "and", "for", "with", "per", "of", "a", "an", "in", "mix"]);
const words = (s: string) => new Set(s.toLowerCase().replace(/[^a-z0-9 ]/g, " ").split(/\s+/).filter((w) => w.length > 1 && !STOP.has(w)));

/** How alike two names are, 0 to 1: the share of words they have in common, or 1 when one holds the other. */
export function nameLikeness(a: string, b: string): number {
  const [x, y] = [squash(a), squash(b)];
  if (!x || !y) return 0;
  if (x === y || (x.length >= 4 && y.includes(x)) || (y.length >= 4 && x.includes(y))) return 1;
  const [wa, wb] = [words(a), words(b)];
  const shared = [...wa].filter((w) => wb.has(w)).length;
  return shared / Math.max(1, Math.min(wa.size, wb.size));
}

/** What a supplier's line can be logged as: one of the job's estimated materials, or a price list item. */
export interface MaterialCandidate {
  service_id: string | null;
  name: string;
  unit: string;
  /** On the job's lines (job_estimated_materials), not just in the price list. */
  estimated: boolean;
}

/**
 * The material each line seems to be, by name and unit: the closest one in the same unit, if it's at
 * least 60% alike by name. One of the job's estimated materials comes before a price list item.
 * Null for a line with no unit, or nothing close.
 */
export function matchLines(lines: readonly ReceiptLine[], candidates: readonly MaterialCandidate[]): Array<number | null> {
  return lines.map((l) => {
    const unit = unitKey(l.unit);
    if (!unit) return null;
    let best: { index: number; score: number } | null = null;
    candidates.forEach((c, index) => {
      if (unitKey(c.unit) !== unit) return;
      const likeness = nameLikeness(l.description, c.name);
      if (likeness < 0.6) return;
      const score = likeness + (c.estimated ? 0.01 : 0);
      if (!best || score > best.score) best = { index, score };
    });
    return (best as { index: number } | null)?.index ?? null;
  });
}
