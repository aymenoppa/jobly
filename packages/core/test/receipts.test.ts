import { describe, expect, it } from "vitest";
import { jobNumberOf, matchLines, nameLikeness, readFields, suggestJob, unitKey, type JobCandidate, type ReceiptReading } from "../src";

const jobs: JobCandidate[] = [
  { id: "a", number: 1042, po_number: "PO-7781", property: { line1: "18 Birch Lane" } },
  { id: "b", number: 1043, po_number: null, property: { line1: "4 Elm Street" } },
  { id: "c", number: 1044, po_number: "7781-B", property: { line1: "4 Elm St, Unit 2" } },
];
const ref = (more: Partial<ReceiptReading["job_reference"]>) => ({ job_number: null, po_number: null, address: null, ...more });

describe("which job a receipt is for", () => {
  it("goes by the job number first", () => {
    expect(suggestJob(ref({ job_number: "Job #1043", address: "18 Birch Ln" }), jobs)).toEqual({ id: "b", why: "job_number" });
    expect(jobNumberOf("J-1042")).toBe(1042);
    expect(jobNumberOf("none")).toBeNull();
  });

  it("then the PO number, however it's written", () => {
    expect(suggestJob(ref({ po_number: "po 7781" }), jobs)).toEqual({ id: "a", why: "po_number" });
  });

  it("then the street address, with street words written either way", () => {
    expect(suggestJob(ref({ address: "18 Birch Ln, Fairview VA" }), jobs)).toEqual({ id: "a", why: "address" });
  });

  it("suggests nothing when more than one job fits, or nothing does", () => {
    expect(suggestJob(ref({ address: "4 Elm St" }), jobs)).toBeNull();
    expect(suggestJob(ref({ job_number: "9999" }), jobs)).toBeNull();
    expect(suggestJob(ref({ address: "Birch Lane" }), jobs)).toBeNull();
    // A job number nobody can see falls through to what else it says.
    expect(suggestJob(ref({ job_number: "9999", po_number: "PO-7781" }), jobs)).toEqual({ id: "a", why: "po_number" });
  });
});

describe("which material a supplier's line is", () => {
  const candidates = [
    { service_id: "hot", name: "Hot-mix asphalt surface", unit: "ton", estimated: true },
    { service_id: null, name: "Tack coat", unit: "gal", estimated: true },
    { service_id: "stone", name: "57 stone", unit: "ton", estimated: false },
    { service_id: "hot2", name: "Hot mix asphalt surface", unit: "ton", estimated: false },
  ];
  const line = (description: string, unit: string | null) => ({ description, quantity: 1, unit, unit_price: 1, amount: 1 });

  it("matches by name and unit, the job's own estimate before the price list", () => {
    expect(matchLines([line("HOT MIX ASPHALT SURFACE 9.5MM", "TN"), line("Tack Coat CSS-1h", "Gallons"), line("#57 Stone", "tons")], candidates)).toEqual([0, 1, 2]);
  });

  it("matches nothing in another unit, with no unit, or by too little of its name", () => {
    expect(matchLines([line("Hot-mix asphalt surface", "load"), line("Tack coat", null), line("Asphalt rake", "ea")], candidates)).toEqual([null, null, null]);
  });

  it("reads units as suppliers write them", () => {
    expect(["TN", "Tons", "t"].map(unitKey)).toEqual(["ton", "ton", "ton"]);
    expect(["CY", "cu yd", "yd3"].map(unitKey)).toEqual(["yd³", "yd³", "yd³"]);
    expect(unitKey("bundle")).toBe("bundle");
    expect(nameLikeness("Sealer", "Asphalt sealer")).toBe(1);
  });
});

it("says which of the form's fields a reading filled", () => {
  const reading: ReceiptReading = { kind: "receipt", vendor: "Shell", date: "2026-11-10", invoice_number: null, subtotal: null, tax: null, total: 61.2, category: "Fuel", lines: [], job_reference: ref({}) };
  expect(readFields(reading)).toEqual(["vendor", "date", "amount", "category"]);
});
