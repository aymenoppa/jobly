/**
 * Recording a refund by hand (features/invoices/recordRefund.ts): the negative payment, "Take it off
 * the invoice too" doing to the invoice what the refund through Stripe does, what the office is told
 * after, and what it's told before a paid invoice past its due date is owed again
 * (20261113000430_owed_again_without_chasing.sql).
 */
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";

const calls = vi.hoisted(() => [] as Array<{ op: string; on: string; args: unknown }>);
/** What the database holds: the invoice's payments, the invoice as it reads once the refund is on it, and whether the write-off is refused. */
const state = vi.hoisted(() => ({
  payments: [] as Array<{ amount: number; method: string; processor: string | null }>,
  invoice: null as { status: string; balance_due: number } | null,
  writeOffError: null as { code: string; message: string } | null,
}));
vi.mock("../src/lib/api", async (importOriginal) => {
  const real = await importOriginal<typeof import("../src/lib/api")>();
  const from = (on: string) => ({
    select: () => ({
      eq: () => (on === "payments" ? Promise.resolve({ data: state.payments, error: null }) : { maybeSingle: () => Promise.resolve({ data: state.invoice, error: null }) }),
    }),
    insert: (args: unknown) => (calls.push({ op: "insert", on, args }), Promise.resolve({ data: null, error: null })),
    update: (args: unknown) => (calls.push({ op: "update", on, args }), { eq: () => Promise.resolve({ data: null, error: state.writeOffError }) }),
  });
  return { ...real, supabase: () => ({ from }) };
});

const { owedAgainNote, recordRefund, refundToasts } = await import("../src/features/invoices/recordRefund");

const check = { amount: 500, method: "check" };
const refund = (amount: number, takeOff: boolean, notes: string | null = null) =>
  recordRefund({ companyId: "c1", invoice: { id: "i1", client_id: "cl1" }, payment: check, amount, receivedAt: "2026-11-13T18:00:00.000Z", notes, takeOff });

beforeEach(() => {
  calls.splice(0);
  state.payments = [{ amount: 500, method: "check", processor: null }];
  state.invoice = { status: "overdue", balance_due: 100 };
  state.writeOffError = null;
});

describe("a refund recorded by hand", () => {
  it("goes on the invoice as a negative payment by the same method, with its note", async () => {
    expect(await refund(100, false, "Check 2210")).toEqual({ written_off: false, still_owed: 0 });
    expect(calls).toEqual([
      { op: "insert", on: "payments", args: { company_id: "c1", invoice_id: "i1", client_id: "cl1", amount: -100, method: "check", received_at: "2026-11-13T18:00:00.000Z", notes: "Refund: Check 2210" } },
    ]);
  });

  it("is checked against the payments as they are now, in case it was just refunded elsewhere", async () => {
    state.payments.push({ amount: -450, method: "check", processor: null });
    await expect(refund(100, true)).rejects.toThrow("Only $50.00 of this payment is left to refund.");
    state.payments.push({ amount: -50, method: "check", processor: null });
    await expect(refund(100, true)).rejects.toThrow("This payment has already been refunded.");
    expect(calls).toEqual([]);
  });
});

// As POST /payments/:id/refund does for a refund through Stripe (apps/api/src/routes/autopay.ts).
describe("Take it off the invoice too", () => {
  it("writes off the balance the refund put back, so a partial refund leaves the invoice settled", async () => {
    expect(await refund(100, true)).toEqual({ written_off: true, still_owed: 0 });
    expect(calls.map((c) => `${c.op} ${c.on}`)).toEqual(["insert payments", "update invoices"]);
    expect(calls[1]!.args).toEqual({ status: "written_off" });
  });

  it("writes nothing off when other money is still owed, and says how much is", async () => {
    state.invoice = { status: "overdue", balance_due: 250 };
    expect(await refund(100, true)).toEqual({ written_off: false, still_owed: 250 });
    expect(calls.map((c) => c.op)).toEqual(["insert"]);
  });

  it("has nothing to take off an invoice that isn't owed after the refund", async () => {
    // It had been overpaid, or is void.
    for (const invoice of [{ status: "paid", balance_due: 0 }, { status: "paid", balance_due: -20 }, { status: "void", balance_due: 100 }, { status: "written_off", balance_due: 100 }]) {
      state.invoice = invoice;
      expect(await refund(100, true), JSON.stringify(invoice)).toEqual({ written_off: false, still_owed: 0 });
    }
    expect(calls.every((c) => c.op === "insert")).toBe(true);
  });

  it("keeps the refund when the write-off is refused, and doesn't say it came off", async () => {
    state.writeOffError = { code: "22023", message: "A bank payment for this is on its way" };
    const result = await refund(100, true);
    expect(result).toEqual({ written_off: false, still_owed: 0 });
    expect(refundToasts(result, true)).toEqual({ success: "Refund recorded", note: null });
  });

  it("leaves the balance on the invoice when it isn't ticked", async () => {
    expect(await refund(100, false)).toEqual({ written_off: false, still_owed: 0 });
    expect(calls.map((c) => c.op)).toEqual(["insert"]);
  });
});

describe("what the office is told after a refund recorded by hand", () => {
  it("says it came off the invoice, or just that it's recorded", () => {
    expect(refundToasts({ written_off: true, still_owed: 0 }, true)).toEqual({ success: "Refund recorded and taken off the invoice", note: null });
    expect(refundToasts({ written_off: false, still_owed: 0 }, false)).toEqual({ success: "Refund recorded", note: null });
  });

  it("says when the box was ticked but other money is still owed, and how to stop collecting it", () => {
    expect(refundToasts({ written_off: false, still_owed: 250 }, true)).toEqual({
      success: "Refund recorded",
      note: { title: "The balance wasn't taken off", description: "$250.00 is still owed on this invoice, including the refunded part. Write it off from the invoice menu if you don't want it collected." },
    });
  });
});

describe("what the office is told before a paid invoice is owed again", () => {
  const paid = { status: "paid", due_on: "2026-11-01", balance_due: 0 };
  const note = "This invoice will show as past due. The client isn't reminded today.";

  it("says a paid invoice past its due date will show as past due, and that the client isn't reminded today", () => {
    expect(owedAgainNote(paid, 100, "2026-11-13")).toBe(note);
  });

  it("says nothing when it won't be past due", () => {
    // Due today or later, or with no due date.
    expect(owedAgainNote({ ...paid, due_on: "2026-11-13" }, 100, "2026-11-13")).toBeNull();
    expect(owedAgainNote({ ...paid, due_on: "2026-12-01" }, 100, "2026-11-13")).toBeNull();
    expect(owedAgainNote({ ...paid, due_on: null }, 100, "2026-11-13")).toBeNull();
    // Overpaid by more than comes back: still nothing owed.
    expect(owedAgainNote({ ...paid, balance_due: -150 }, 100, "2026-11-13")).toBeNull();
    expect(owedAgainNote(paid, 0, "2026-11-13")).toBeNull();
  });

  it("says nothing new about an invoice that's past due already", () => {
    expect(owedAgainNote({ status: "overdue", due_on: "2026-11-01", balance_due: 50 }, 100, "2026-11-13")).toBeNull();
  });

  it("is said in the refund dialogs when the refund stays on the invoice, and on the toast when a payment is removed", () => {
    const page = readFileSync(new URL("../src/features/invoices/InvoicePage.tsx", import.meta.url), "utf8");
    expect(page).toContain("description: owedAgainNote(inv, Number(payment.amount), today) ?? undefined,");
    // Both dialogs: the manual one, and the refund through Stripe.
    expect(page.match(/The balance goes back up by the refund, and the client will be asked for it\.\$?\{pastDue \? ` \$\{pastDue\}` : ""\}/g)).toHaveLength(2);
    // The manual dialog starts ticked, as the Stripe one does, and goes through recordRefund.
    expect(page).toContain("const [takeOff, setTakeOff] = useState(true);");
    expect(page).toContain("return recordRefund({");
    // And the page says so while the notice waits, with the late fee's day counted from when it was owed again.
    expect(page).toContain(`{inv.past_due_notice_pending ? " It was paid and is owed again, so the client isn't reminded today." : ""}`);
    expect(page).toContain("const feeDay = lateFeeOn(inv, lateFee, session.company.timezone);");
  });

  it("reads a balance written off by a refund as money given back, not a debt given up on", () => {
    const page = readFileSync(new URL("../src/features/invoices/InvoicePage.tsx", import.meta.url), "utf8");
    expect(page).toContain("? `Refunded and taken off${inv.written_off_at ? ` on ${formatDate(inv.written_off_at)}` : \"\"}: the ${formatMoneyCents(balance)} given back isn't counted as owed.`");
  });
});
