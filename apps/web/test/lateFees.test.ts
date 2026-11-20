import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { lateFeeControls } from "../src/features/invoices/lateFees";

const source = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

const work = { kind: null };
const fee = { kind: "late_fee" };
const invoice = (over: Partial<Parameters<typeof lateFeeControls>[0]> = {}) => ({ kind: "standard", status: "overdue", late_fee_at: null, no_late_fee: false, lines: [work], ...over });
const on = { feesOn: true, fromStripe: false };

// 20261113000420_late_fee_off_for_an_invoice.sql: remove_late_fee and invoices.no_late_fee.
describe("late fees on the invoice page", () => {
  it("offers Remove late fee on an invoice that has one, partly paid or paid ones too", () => {
    for (const status of ["sent", "partially_paid", "overdue", "paid", "draft"]) {
      expect(lateFeeControls(invoice({ status, late_fee_at: "2026-11-01T08:00:00Z", lines: [work, fee] }), on), status).toEqual({ remove: true, tick: false, note: null });
    }
    // Whatever the business's setting says now: the fee is on it.
    expect(lateFeeControls(invoice({ late_fee_at: "2026-11-01T08:00:00Z", lines: [work, fee] }), { feesOn: false, fromStripe: false }).remove).toBe(true);
  });

  it("leaves a void or written-off invoice as it is", () => {
    for (const status of ["void", "written_off"]) {
      expect(lateFeeControls(invoice({ status, late_fee_at: "2026-11-01T08:00:00Z", lines: [work, fee] }), on), status).toEqual({ remove: false, tick: false, note: null });
      expect(lateFeeControls(invoice({ status }), on).tick, status).toBe(false);
    }
  });

  it("shows the No late fee tick on an invoice that could still get one", () => {
    for (const status of ["draft", "sent", "partially_paid", "overdue"]) {
      expect(lateFeeControls(invoice({ status }), on), status).toEqual({ remove: false, tick: true, note: null });
    }
    // Ticked, it stays to be seen (and unticked), even if the business stopped charging late fees.
    expect(lateFeeControls(invoice({ no_late_fee: true }), { feesOn: false, fromStripe: false }).tick).toBe(true);
  });

  it("shows no tick where a fee never goes on anyway", () => {
    expect(lateFeeControls(invoice(), { feesOn: false, fromStripe: false }).tick).toBe(false);
    expect(lateFeeControls(invoice({ status: "paid" }), on).tick).toBe(false);
    expect(lateFeeControls(invoice({ kind: "deposit" }), on).tick).toBe(false);
    expect(lateFeeControls(invoice(), { feesOn: true, fromStripe: true }).tick).toBe(false);
    // Its one fee went on and was taken off by hand in a draft before this: it never gets another.
    expect(lateFeeControls(invoice({ late_fee_at: "2026-11-01T08:00:00Z" }), on)).toEqual({ remove: false, tick: false, note: null });
  });

  it("says a removed fee won't come back, in place of the tick", () => {
    expect(lateFeeControls(invoice({ late_fee_at: "2026-11-01T08:00:00Z", no_late_fee: true }), on)).toEqual({
      remove: false, tick: false, note: "Late fee removed. No late fee goes on this invoice again.",
    });
  });

  it("is on the page: the menu item asks first and calls the database's function, and the tick saves no_late_fee", () => {
    const page = source("../src/features/invoices/InvoicePage.tsx");
    expect(page).toContain(`supabase().rpc("remove_late_fee", { p_invoice: id })`);
    expect(page).toContain(`label: "Remove late fee",`);
    expect(page).toContain("hidden: !fees.remove || charging,");
    expect(page).toContain("onChange={(e) => saveField({ no_late_fee: e.target.checked })} /> No late fee on this invoice");
    expect(page).toContain("{fees.note && <span className=\"muted small\">{fees.note}</span>}");
    // The lines come with their kind, so the fee line is found.
    expect(page).toMatch(/lines:invoice_line_items\([^)]*\bkind\)/);
  });
});
