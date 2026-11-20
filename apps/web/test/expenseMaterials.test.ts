/**
 * A supplier invoice's lines logged as a job's materials (jobs/expenseMaterials.ts): what's logged
 * against the job's estimate counts through its line items and the rest as an expense, once each,
 * whichever boxes are ticked or unticked on the way; a material the crew already logged isn't logged
 * twice; and a receipt that looks to be in already is asked about.
 */
import type { MaterialCandidate, ReceiptLine } from "@jobly/core/receipts";
import { jobCost } from "@jobly/core/reports";
import { describe, expect, it } from "vitest";
import { alreadyLoggedNote, lookalikes, materialsPlan, planWords, sameReceiptQuestion, type KnownExpense } from "@/features/jobs/expenseMaterials";

const ASPHALT = "a0000000-0000-4000-8000-000000000001";
const TACK = "a0000000-0000-4000-8000-000000000002";
const SEALER = "a0000000-0000-4000-8000-000000000003";
// On the job's estimate: asphalt and tack. On the price list only: sealer.
const candidates: MaterialCandidate[] = [
  { service_id: ASPHALT, name: "Hot mix asphalt", unit: "ton", estimated: true },
  { service_id: TACK, name: "Tack coat", unit: "gal", estimated: true },
  { service_id: SEALER, name: "Sealer", unit: "gal", estimated: false },
];
const asphalt: ReceiptLine = { description: "HMA surface 9.5mm", quantity: 44, unit: "ton", unit_price: 92, amount: 4048 };
const delivery: ReceiptLine = { description: "Delivery", quantity: null, unit: null, unit_price: null, amount: 150 };
const tack: ReceiptLine = { description: "Tack", quantity: 30, unit: "gal", unit_price: 4, amount: null };
const sealer: ReceiptLine = { description: "Sealer", quantity: 10, unit: "gal", unit_price: 25, amount: 250 };

describe("how a supplier invoice counts in the job's costs", () => {
  it("counts the logged asphalt through the line items and the delivery as an expense: never the asphalt twice", () => {
    // The reviewer's first: 44 t of asphalt ($4,048) plus a $150 delivery nothing matches, "Also log" ticked.
    const plan = materialsPlan({ lines: [asphalt, delivery], candidates, choices: [0, -1], logMaterials: true, amount: 4198, ticked: false, ticket: "INV-8841" });
    expect(plan.toLog).toEqual([{ service_id: ASPHALT, name: "Hot mix asphalt", unit: "ton", quantity: 44, ticket: "INV-8841" }]);
    expect(plan.inLineAmount).toBe(4048);
    expect(plan.counted).toBe(150);
    expect(plan.inLineAmount + plan.counted).toBe(4198);
    expect(planWords(plan, { logMaterials: true, ticked: false })).toBe(
      "In job costing, $4,048.00 counts through the job's line items (the materials on its estimate, at the line items' cost) and the other $150.00 counts as an expense. It's saved as two expenses with the same receipt, so neither part is counted twice.",
    );
  });

  it("drops nothing when Also log is ticked and then unticked: the expense counts in full again", () => {
    // The reviewer's second. Every line matches the estimate, so ticked, all of it is in the line items.
    const input = { lines: [asphalt], candidates, choices: [0], amount: 4048, ticked: false };
    const ticked = materialsPlan({ ...input, logMaterials: true });
    expect([ticked.inLineAmount, ticked.counted, ticked.toLog.length]).toEqual([4048, 0, 1]);
    // Unticked again, nothing is logged, and nothing is left marked as in the line items.
    const unticked = materialsPlan({ ...input, logMaterials: false });
    expect([unticked.inLineAmount, unticked.counted, unticked.toLog.length]).toEqual([0, 4048, 0]);
    expect(planWords(unticked, { logMaterials: false, ticked: false })).toBeNull();
    // And ticked once more it's the same answer as the first time: the order doesn't matter.
    expect(materialsPlan({ ...input, logMaterials: true })).toEqual(ticked);
  });

  it("is the same whichever order the lines' choices and the boxes were set in", () => {
    const lines = [asphalt, delivery, sealer];
    const end = { lines, candidates, choices: [0, -1, 2], logMaterials: true, amount: 4448, ticked: false };
    const direct = materialsPlan(end);
    // Getting there by another road (a line matched and unmatched, the box off and on) ends in the same place.
    materialsPlan({ ...end, choices: [-1, -1, -1], logMaterials: false });
    materialsPlan({ ...end, choices: [0, 0, 2], logMaterials: true });
    expect(materialsPlan({ ...end })).toEqual(direct);
    // Asphalt through the lines; delivery, and the sealer that isn't on this job's estimate, as an expense.
    expect([direct.inLineAmount, direct.counted]).toEqual([4048, 400]);
    expect(direct.toLog.map((m) => m.name)).toEqual(["Hot mix asphalt", "Sealer"]);
    expect(direct.lines.map((l) => [l.log, l.inLines])).toEqual([[true, true], [false, false], [true, false]]);
  });

  it("doesn't log a material the crew already logged tickets for, and still doesn't count its cost twice", () => {
    // The crew's load tickets: 44 tons already on the job.
    const before = [{ service_id: ASPHALT, unit: "ton", quantity: 20 }, { service_id: ASPHALT, unit: "Ton", quantity: "24" }, { service_id: TACK, unit: "drum", quantity: 1 }];
    const input = { lines: [asphalt, delivery], candidates, choices: [0, -1], before, logMaterials: true, amount: 4198, ticked: false };
    const plan = materialsPlan(input);
    expect(plan.toLog).toEqual([]);
    expect(plan.lines[0]).toMatchObject({ already: 44, log: false, inLines: true });
    // Its $4,048 counts through the line items by those tickets; only the delivery is an expense.
    expect([plan.inLineAmount, plan.counted]).toEqual([4048, 150]);
    expect(alreadyLoggedNote(plan.lines[0]!)).toBe('44 ton of Hot mix asphalt are already logged on this job, so this line isn\'t logged again. Tick "Log it too" if this invoice is for more.');
    // "Log it too": this invoice is for more of it.
    const more = materialsPlan({ ...input, again: [true, false] });
    expect(more.toLog.map((m) => m.quantity)).toEqual([44]);
    expect([more.inLineAmount, more.counted]).toEqual([4048, 150]);
    expect(alreadyLoggedNote(more.lines[0]!)).toBe("44 ton of Hot mix asphalt are already logged on this job. This line is logged on top of that.");
    // Tickets in another unit aren't the same thing, and a line with nothing logged before says nothing.
    expect(materialsPlan({ ...input, lines: [tack], choices: [1] }).lines[0]).toMatchObject({ already: 0, log: true });
    expect(alreadyLoggedNote(plan.lines[1]!)).toBeNull();
  });

  it("keeps a line with no amount on the invoice in the expense, and says so", () => {
    const plan = materialsPlan({ lines: [{ ...asphalt, unit_price: null, amount: null }, delivery], candidates, choices: [0, -1], logMaterials: true, amount: 4198, ticked: false });
    expect([plan.inLineAmount, plan.counted]).toEqual([0, 4198]);
    expect(planWords(plan, { logMaterials: true, ticked: false })).toContain("One line logged against the estimate shows no amount on the invoice, so it stays in the expense");
    // A quantity at a price is an amount.
    expect(materialsPlan({ lines: [tack], candidates, choices: [1], logMaterials: true, amount: 120, ticked: false }).inLineAmount).toBe(120);
  });

  it("never takes more off the expense than the expense is, and the office's own tick is the whole of it", () => {
    // The lines come to more than the total typed (a credit on the invoice, say).
    const over = materialsPlan({ lines: [asphalt], candidates, choices: [0], logMaterials: true, amount: 4000, ticked: false });
    expect([over.inLineAmount, over.counted]).toEqual([4000, 0]);
    expect(planWords(over, { logMaterials: true, ticked: false })).toBe("In job costing, all $4,000.00 counts through the job's line items (the materials on its estimate, at the line items' cost), so the expense isn't counted on top of them.");
    const ticked = materialsPlan({ lines: [asphalt, delivery], candidates, choices: [-1, -1], logMaterials: false, amount: 4198, ticked: true });
    expect([ticked.inLineAmount, ticked.counted, ticked.toLog.length]).toEqual([4198, 0, 0]);
    expect(planWords(ticked, { logMaterials: false, ticked: true })).toBe("All of it is marked as already in the job's line item costs, so job costing won't count this expense on top of them.");
    // Only price list items logged: nothing on the job's lines stands for them, so all of it is an expense.
    const offEstimate = materialsPlan({ lines: [sealer], candidates, choices: [2], logMaterials: true, amount: 250, ticked: false });
    expect([offEstimate.inLineAmount, offEstimate.counted]).toEqual([0, 250]);
    expect(planWords(offEstimate, { logMaterials: true, ticked: false })).toBe("None of what's logged is on this job's estimate, so the whole $250.00 counts as an expense.");
    // No amount typed yet.
    expect(materialsPlan({ lines: [asphalt], candidates, choices: [0], logMaterials: true, amount: Number.NaN, ticked: false })).toMatchObject({ inLineAmount: 0, counted: 0 });
  });
});

describe("the job's costs with a supplier invoice logged", () => {
  // The job: 40 tons of asphalt estimated at $90 a ton. The invoice: 44 tons ($4,048) and a $150 delivery.
  const lines = [{ quantity: 40, unit_cost: 90, service_id: ASPHALT, name: "Hot mix asphalt", unit: "ton" }];
  const logged = [{ service_id: ASPHALT, name: "Hot mix asphalt", unit: "ton", quantity: 44 }];
  const cost = (expenses: Array<{ amount: number; in_line_costs: boolean }>, materials = logged) => jobCost({ price: 10000, lines, labor: 0, crewPay: [], expenses, logged: materials }).cost;

  it("counted the asphalt twice the old way, saved as one expense with the materials logged", () => {
    // 44 tons through the lines ($3,960) and the whole $4,198 again as an expense.
    expect(cost([{ amount: 4198, in_line_costs: false }])).toBe(3960 + 4198);
  });

  it("dropped the invoice the old way, once marked as in the line items with nothing logged", () => {
    // "Also log" ticked (which ticked the box) and unticked: no materials, and the expense left out. Only the estimate is left.
    expect(cost([{ amount: 4198, in_line_costs: true }], [])).toBe(3600);
  });

  it("counts each part once as it's saved now", () => {
    const plan = materialsPlan({ lines: [asphalt, delivery], candidates, choices: [0, -1], logMaterials: true, amount: 4198, ticked: false });
    // Two expenses: the part in the line items, and the rest.
    const saved = [{ amount: plan.inLineAmount, in_line_costs: true }, { amount: plan.counted, in_line_costs: false }];
    expect(cost(saved)).toBe(3960 + 150);
    // Unticked, nothing is logged and the expense counts in full beside the estimate, as any expense.
    const off = materialsPlan({ lines: [asphalt, delivery], candidates, choices: [0, -1], logMaterials: false, amount: 4198, ticked: false });
    expect(cost([{ amount: off.counted, in_line_costs: false }], [])).toBe(3600 + 4198);
    // The crew's tickets already there: nothing logged again, the delivery alone an expense.
    const tickets = materialsPlan({ lines: [asphalt, delivery], candidates, choices: [0, -1], before: [{ service_id: ASPHALT, unit: "ton", quantity: 44 }], logMaterials: true, amount: 4198, ticked: false });
    expect(tickets.toLog).toEqual([]);
    expect(cost([{ amount: tickets.inLineAmount, in_line_costs: true }, { amount: tickets.counted, in_line_costs: false }])).toBe(3960 + 150);
  });
});

describe("the same receipt twice", () => {
  const known: KnownExpense[] = [
    { id: "e1", vendor: "Valley Asphalt", amount: 4198, incurred_on: "2026-11-03", invoice_number: "INV-8841", job: { number: 12 } },
    { id: "e2", vendor: "Home Depot", amount: 61.4, incurred_on: "2026-11-03", invoice_number: null },
    // One receipt saved as two expenses: the part in the line items, and the rest.
    { id: "e3", vendor: "Quarry Co", amount: 900, receipt_total: 1000, incurred_on: "2026-11-04", invoice_number: "Q-77", receipt_path: "co/receipts/q.pdf" },
    { id: "e4", vendor: "Quarry Co", amount: 100, receipt_total: 1000, incurred_on: "2026-11-04", invoice_number: "Q-77", receipt_path: "co/receipts/q.pdf" },
  ];

  it("is noticed by its invoice number, or by its vendor, day and total", () => {
    expect(lookalikes({ vendor: "valley asphalt ", total: 1, date: "2026-12-01", invoice_number: "inv-8841" }, known).map((e) => e.id)).toEqual(["e1"]);
    expect(lookalikes({ vendor: "HOME DEPOT", total: 61.4, date: "2026-11-03", invoice_number: null }, known).map((e) => e.id)).toEqual(["e2"]);
    // The receipt's whole total, not either expense's part of it, and listed once.
    expect(lookalikes({ vendor: "Quarry Co", total: 1000, date: "2026-11-04", invoice_number: null }, known).map((e) => e.id)).toEqual(["e3"]);
    expect(lookalikes({ vendor: "Quarry Co", total: 900, date: "2026-11-04", invoice_number: null }, known)).toEqual([]);
    // The same number from the read with no vendor still counts; from another vendor it doesn't.
    expect(lookalikes({ vendor: null, total: 5, date: "2026-12-01", invoice_number: "INV-8841" }, known).map((e) => e.id)).toEqual(["e1"]);
    expect(lookalikes({ vendor: "Other Paving", total: 5, date: "2026-12-01", invoice_number: "INV-8841" }, known)).toEqual([]);
  });

  it("isn't another day's, another total's, or a receipt with no vendor", () => {
    expect(lookalikes({ vendor: "Home Depot", total: 61.4, date: "2026-11-04", invoice_number: null }, known)).toEqual([]);
    expect(lookalikes({ vendor: "Home Depot", total: 61.41, date: "2026-11-03", invoice_number: null }, known)).toEqual([]);
    expect(lookalikes({ vendor: null, total: 61.4, date: "2026-11-03", invoice_number: null }, [{ id: "x", vendor: null, amount: 61.4, incurred_on: "2026-11-03" }])).toEqual([]);
  });

  it("is asked about before saving, saying which expense it looks like", () => {
    expect(sameReceiptQuestion([])).toBeNull();
    expect(sameReceiptQuestion([known[0]!])).toEqual({
      title: "This looks like a receipt that's already in",
      body: "Valley Asphalt, $4,198.00 on Nov 3, 2026, invoice INV-8841, on job #12. Saving this one as well would count it twice.",
      confirmLabel: "Save it anyway",
      cancelLabel: "Go back",
    });
    expect(sameReceiptQuestion([known[2]!])!.body).toBe("Quarry Co, $1,000.00 on Nov 4, 2026, invoice Q-77. Saving this one as well would count it twice.");
  });
});
