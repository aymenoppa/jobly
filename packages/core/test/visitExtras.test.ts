import { describe, expect, it } from "vitest";
import { costedExtras, extraBillingHint, extraState, extraStateText, extrasByVisit, extrasToReview, extrasTotal, takesExtras, visitTakesExtras, type VisitExtra } from "../src/visitExtras";

const extra = (over: Partial<VisitExtra> = {}): VisitExtra => ({ id: "x1", visit_id: "v1", name: "Mulch", quantity: 2, unit: "yd", unit_price: 60, invoice_id: null, ...over });

describe("where an extra stands", () => {
  it("waits for its visit to be done, then is ready, then is on an invoice", () => {
    expect(extraState(extra(), { id: "v1", status: "scheduled" })).toBe("waiting");
    expect(extraState(extra(), { id: "v1", status: "in_progress" })).toBe("waiting");
    expect(extraState(extra(), { id: "v1", status: "completed" })).toBe("ready");
    expect(extraState(extra({ invoice_id: "i1" }), { id: "v1", status: "completed", invoice_id: "i1" })).toBe("invoiced");
  });

  it("isn't billed when its visit was cancelled or deleted, unless an invoice already has it", () => {
    expect(extraState(extra(), { id: "v1", status: "cancelled" })).toBe("not_billed");
    expect(extraState(extra({ visit_id: null, visit_was_on: "2026-11-12" }), null)).toBe("not_billed");
    expect(extraState(extra(), undefined)).toBe("not_billed");
    expect(extraState(extra({ invoice_id: "i1" }), { id: "v1", status: "cancelled" })).toBe("invoiced");
  });

  it("says so in a few words", () => {
    expect(extraStateText("invoiced", 12)).toBe("On invoice #12");
    expect(extraStateText("invoiced")).toBe("Invoiced");
    expect(extraStateText("ready")).toBe("Ready to invoice");
    expect(extraStateText("waiting")).toBe("Billed when the visit is done");
    expect(extraStateText("not_billed")).toBe("Not billed");
  });
});

describe("where extra work can go", () => {
  it("on a repeating job that's still open, as the database decides", () => {
    expect(takesExtras({ kind: "recurring", status: "active" })).toBe(true);
    expect(takesExtras({ kind: "recurring", status: "requires_invoicing" })).toBe(true);
    expect(takesExtras({ kind: "recurring", status: "archived" })).toBe(false);
    expect(takesExtras({ kind: "one_off", status: "active" })).toBe(false);
  });

  it("on a visit that isn't cancelled or on an invoice yet", () => {
    expect(visitTakesExtras({ status: "scheduled", invoice_id: null })).toBe(true);
    expect(visitTakesExtras({ status: "completed" })).toBe(true);
    expect(visitTakesExtras({ status: "completed", invoice_id: "i1" })).toBe(false);
    expect(visitTakesExtras({ status: "cancelled" })).toBe(false);
  });
});

describe("when it's billed", () => {
  it("with its visit's invoice, the month's, or added to a fixed price's next invoice", () => {
    expect(extraBillingHint({ kind: "recurring", billing_mode: "per_visit", pricing: "per_visit", invoice_schedule: "after_visit" })).toBe("Billed once, on this visit's invoice.");
    expect(extraBillingHint({ kind: "recurring", billing_mode: "fixed_schedule", pricing: "per_visit", invoice_schedule: "monthly" })).toBe("Billed once, on the month's invoice with this visit.");
    expect(extraBillingHint({ kind: "recurring", billing_mode: "fixed_schedule", pricing: "per_visit", invoice_schedule: "as_needed" })).toBe("Billed once, on this visit's invoice.");
    expect(extraBillingHint({ kind: "recurring", billing_mode: "fixed_schedule", pricing: "fixed", invoice_schedule: "monthly" })).toBe("Billed once, added to the month's invoice after the visit is done.");
    expect(extraBillingHint({ kind: "recurring", billing_mode: "fixed_schedule", pricing: "fixed", invoice_schedule: "as_needed" })).toBe("Billed once, added to the next invoice after the visit is done.");
  });
});

describe("adding extras up", () => {
  it("rounds each to the cent as an invoice line is", () => {
    expect(extrasTotal([{ quantity: 2, unit_price: 60 }, { quantity: 1.5, unit_price: 33.33 }])).toBe(170);
    expect(extrasTotal([{ quantity: "0.333", unit_price: "10.00" }, { quantity: "0.333", unit_price: "10.00" }])).toBe(6.66);
    expect(extrasTotal([])).toBe(0);
  });

  it("groups them by visit, leaving out one whose visit was deleted", () => {
    const map = extrasByVisit([extra(), extra({ id: "x2" }), extra({ id: "x3", visit_id: "v2" }), extra({ id: "x4", visit_id: null })]);
    expect(map.get("v1")?.map((e) => e.id)).toEqual(["x1", "x2"]);
    expect(map.get("v2")?.map((e) => e.id)).toEqual(["x3"]);
    expect(map.size).toBe(2);
  });
});

describe("what the job page asks the office about", () => {
  const visits = [{ id: "v1", status: "completed" }, { id: "v2", status: "cancelled" }, { id: "v3", status: "scheduled" }];
  const extras = [
    extra({ id: "office" }),
    extra({ id: "crew", visit_id: "v3", added_in_field_at: "2026-11-13T15:00:00Z" }),
    extra({ id: "crew-billed", added_in_field_at: "2026-11-01T15:00:00Z", invoice_id: "i1" }),
    extra({ id: "cancelled", visit_id: "v2", added_in_field_at: "2026-11-13T15:00:00Z" }),
    extra({ id: "gone", visit_id: null, visit_was_on: "2026-11-20" }),
    extra({ id: "cancelled-billed", visit_id: "v2", invoice_id: "i2" }),
  ];

  it("extras that weren't billed because their visit was cancelled or removed", () => {
    expect(extrasToReview(extras, visits).notBilled.map((e) => e.id)).toEqual(["cancelled", "gone"]);
  });

  it("and ones the crew added that aren't invoiced yet", () => {
    expect(extrasToReview(extras, visits).fromField.map((e) => e.id)).toEqual(["crew"]);
  });

  it("the job's costing counts the ones that are or will be billed, not the unbilled ones of a cancelled or removed visit", () => {
    const costed = costedExtras(extras, visits);
    expect(costed.lines.map((e) => e.id)).toEqual(["office", "crew", "crew-billed", "cancelled-billed"]);
    expect(costed.price).toBe(480);
  });
});
