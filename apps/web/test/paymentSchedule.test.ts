/**
 * A quote's payment schedule on its paper and in the Client Hub (documents/build.ts quoteSchedule),
 * on the office's quote page (quotes/PaymentSchedule.tsx shownSchedule), and on its job
 * (jobs/JobPaymentSchedule.tsx): open, it follows the total; signed, it's what was kept with the
 * approval; on the job, each payment says where it is.
 */
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { quoteDocument, quoteSchedule } from "@/features/documents/build";
import { billsOutsideSchedule, canInvoiceNow, dropPaymentsQuestion, installmentState } from "@/features/jobs/JobPaymentSchedule";
import { fromDraft, shownSchedule, toDraft } from "@/features/quotes/PaymentSchedule";
import { alertAmount, quoteForm } from "@/features/settings/QuoteSettings";

const rows = [
  { kind: "percent", value: 30, due: "approval" },
  { kind: "amount", value: 300, due: "date", on: "2027-03-01" },
  { kind: "rest", due: "work_done" },
];

describe("the schedule editor", () => {
  it("says under the payments that some states cap deposits on home-improvement contracts", () => {
    const editor = readFileSync(new URL("../src/features/quotes/PaymentSchedule.tsx", import.meta.url), "utf8");
    expect(editor).toContain("The one due when they approve is the deposit. {DEPOSIT_LAW_NOTE}");
  });
});

describe("a quote's payment schedule as it prints", () => {
  it("works out an open quote's payments on the total shown", () => {
    expect(quoteSchedule({ payment_schedule: rows, approval: null, total: 1200 }, false)).toEqual([
      { name: "Payment 1", due: "When the quote is approved", amount: 360 },
      { name: "Payment 2", due: "On Mar 1, 2027", amount: 300 },
      { name: "Payment 3", due: "When the work is done", amount: 540 },
    ]);
  });

  it("prints a signed quote's payments as they were kept with the approval, whatever the quote says now", () => {
    const approval = { name: "Erin", payment_schedule: [{ ...rows[0], amount: 300 }, { ...rows[1], amount: 300 }, { ...rows[2], amount: 400 }] };
    expect(quoteSchedule({ payment_schedule: rows, approval, total: 5000 }, true)?.map((p) => p.amount)).toEqual([300, 300, 400]);
    // Signed before schedules were kept: none, rather than one worked out on today's total.
    expect(quoteSchedule({ payment_schedule: rows, approval: { name: "Erin" }, total: 5000 }, true)).toBeNull();
  });

  it("has none without a schedule, and from servers that don't send one", () => {
    expect(quoteSchedule({ payment_schedule: null, approval: null, total: 1000 }, false)).toBeNull();
    expect(quoteSchedule({ approval: null, total: 1000 }, false)).toBeNull();
  });

  it("takes the deposit's place on the paper", () => {
    const data = quoteDocument({ number: 7, subtotal: 1000, discount_amount: 0, tax_amount: 0, total: 1000, deposit_amount: 300, deposit_percent: 30, payment_schedule: rows, status: "sent" }, []);
    expect(data.schedule?.map((p) => p.amount)).toEqual([300, 300, 400]);
    expect(data.deposit).toBe(300);
  });
});

describe("the office's quote page", () => {
  it("shows the payments on the total, and says when they no longer fit it", () => {
    const fits = shownSchedule({ id: "q", status: "draft", total: 1000, payment_schedule: rows });
    expect(fits).toMatchObject({ fits: true, signed: false });
    const over = shownSchedule({ id: "q", status: "draft", total: 500, payment_schedule: [{ kind: "amount", value: 400, due: "approval" }, { kind: "amount", value: 400, due: "work_done" }] });
    expect(over).toMatchObject({ fits: false, left: -300 });
    expect(over.rows.map((r) => r.amount)).toEqual([400, 100]);
  });

  it("shows a signed quote's payments as signed", () => {
    const signed = shownSchedule({ id: "q", status: "converted", total: 9999, payment_schedule: rows, approval: { payment_schedule: [{ ...rows[2], amount: 1000 }] } });
    expect(signed).toMatchObject({ fits: true, signed: true });
    expect(signed.rows.map((r) => r.amount)).toEqual([1000]);
  });

  it("reads the company's switch to send scheduled payments by themselves, off unless it's on", () => {
    expect(quoteForm({}).sendPayments).toBe(false);
    expect(quoteForm({ payment_schedule: { send: true } }).sendPayments).toBe(true);
    expect(quoteForm(null).sendPayments).toBe(false);
  });
});

describe("the job's payments", () => {
  const invoice = (status: string) => ({ id: "i1", number: 12, status, total: 300 });
  const final = { id: "f1", number: 15 };

  it("says where each payment is", () => {
    expect(installmentState({ invoice: invoice("paid") }, null)).toEqual({ kind: "invoiced", invoice: invoice("paid") });
    expect(installmentState({ invoice: invoice("void") }, null)).toEqual({ kind: "voided", invoice: invoice("void") });
    expect(installmentState({ invoice: null }, null)).toEqual({ kind: "to_come" });
    expect(installmentState({ invoice: invoice("sent") }, final)).toEqual({ kind: "invoiced", invoice: invoice("sent") });
    // The last payment's own invoice is the final invoice: it reads as its invoice.
    expect(installmentState({ invoice: { ...invoice("sent"), id: "f1", number: 15 } }, final)).toEqual({ kind: "invoiced", invoice: { ...invoice("sent"), id: "f1", number: 15 } });
    // A final invoice made while several payments had none billed them together: they're on it.
    expect(installmentState({ invoice: { ...invoice("sent"), id: "f1", number: 15 } }, final, true)).toEqual({ kind: "final", invoice: final });
    expect(installmentState({ invoice: null }, final)).toEqual({ kind: "final", invoice: final });
    // One whose own invoice was voided reads as voided, final invoice or not.
    expect(installmentState({ invoice: invoice("void") }, final)).toEqual({ kind: "voided", invoice: invoice("void") });
  });

  it("offers Invoice now for a payment to come or voided, the one for when the work is done too, until the job has its final invoice", () => {
    expect(canInvoiceNow({ kind: "to_come" }, null)).toBe(true);
    expect(canInvoiceNow({ kind: "voided", invoice: invoice("void") }, null)).toBe(true);
    expect(canInvoiceNow({ kind: "invoiced", invoice: invoice("sent") }, null)).toBe(false);
    expect(canInvoiceNow({ kind: "final", invoice: final }, final)).toBe(false);
    expect(canInvoiceNow({ kind: "voided", invoice: invoice("void") }, final)).toBe(false);
  });
});

describe("the schedule editor's rows", () => {
  it("asks a dated payment two ways and saves both as due on a date", () => {
    expect(toDraft({ kind: "percent", value: 30, due: "date", on: "2027-03-01" })).toEqual({ kind: "percent", value: "30", due: "date", on: "2027-03-01", after: "" });
    expect(toDraft({ kind: "percent", value: 30, due: "date", after: 30 })).toEqual({ kind: "percent", value: "30", due: "after", on: "", after: "30" });
    expect(fromDraft({ kind: "percent", value: "30", due: "after", on: "2027-03-01", after: "45" })).toEqual({ kind: "percent", value: 30, due: "date", after: 45 });
    expect(fromDraft({ kind: "percent", value: "30", due: "date", on: "2027-03-01", after: "45" })).toEqual({ kind: "percent", value: 30, due: "date", on: "2027-03-01" });
    // A copy's dated payment comes back with no day, and stays one to set.
    expect(fromDraft(toDraft({ kind: "amount", value: 200, due: "date" }))).toEqual({ kind: "amount", value: 200, due: "date", on: null });
    // Days not typed yet are 0, which the checks turn away.
    expect(fromDraft({ kind: "rest", value: "", due: "after", on: "", after: "" })).toEqual({ kind: "rest", due: "date", after: 0 });
  });
});

describe("changing a job with a payment schedule to bill visit by visit", () => {
  const row = (position: number, amount: number, invoice: { number: number; status: string } | null) => ({
    position, count: 3, amount, invoice: invoice ? { id: `i${position}`, total: amount, ...invoice } : null,
  });

  it("knows which ways of billing can't sit beside a schedule", () => {
    expect(billsOutsideSchedule("one_off", "on_completion")).toBe(false);
    expect(billsOutsideSchedule("one_off", "progress")).toBe(false);
    expect(billsOutsideSchedule("one_off", "per_visit")).toBe(true);
    expect(billsOutsideSchedule("recurring", "fixed_schedule")).toBe(true);
    expect(billsOutsideSchedule("recurring", "on_completion")).toBe(true);
  });

  it("asks before dropping, naming each payment still to come and the ones that stay", () => {
    const question = dropPaymentsQuestion([row(1, 300, { number: 12, status: "paid" }), row(2, 330, null), row(3, 440.5, { number: 14, status: "void" })], false)!;
    expect(question.title).toBe("Drop the 2 payments still to come?");
    expect(question.body).toContain("Saving drops them: Payment 2 of 3 ($330.00), Payment 3 of 3 ($440.50).");
    expect(question.body).toContain("Invoicing after each visit bills the work in full");
    expect(question.body).toContain("Already invoiced, and staying as it is: Payment 1 of 3 (invoice #12). Visit invoices won't take it off.");
    expect(question.confirmLabel).toBe("Drop them and save");
    const one = dropPaymentsQuestion([row(1, 300, null)], true)!;
    expect(one.title).toBe("Drop the payment still to come?");
    expect(one.body).toContain("Invoicing it as repeating work");
    expect(one.body).toContain("Saving drops it: Payment 1 of 3 ($300.00).");
    expect(one.body).not.toContain("Already invoiced");
  });

  it("asks nothing when every payment has its invoice, or the job has no schedule", () => {
    expect(dropPaymentsQuestion([row(1, 300, { number: 12, status: "sent" })], false)).toBeNull();
    expect(dropPaymentsQuestion([], false)).toBeNull();
  });
});

describe("quote alerts' amount", () => {
  it("is off empty, and otherwise an amount above $0 to the cent", () => {
    expect(quoteForm({}).alertOver).toBe("");
    expect(quoteForm({ quotes: { alert_over: 10000 } }).alertOver).toBe("10000");
    expect(quoteForm({ quotes: { alert_over: null } }).alertOver).toBe("");
    expect(alertAmount("")).toBeNull();
    expect(alertAmount("  ")).toBeNull();
    expect(alertAmount("2500.555")).toBe(2500.56);
    expect(() => alertAmount("0")).toThrow("Enter an amount above $0 for quote alerts, or leave it empty.");
  });
});
