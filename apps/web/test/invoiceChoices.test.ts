import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { firstInvoiceKind, invoiceChoices, startingAmount, type InvoiceJob } from "../src/features/jobs/invoiceChoices";

const source = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

const job = (over: Partial<InvoiceJob> = {}): InvoiceJob => ({
  id: "j1", contract_total: 900, deposit: 0, depositInvoice: null, billed: 0, uninvoicedVisits: 0, kind: "one_off", byVisit: false, retainageHeld: 0, finalInvoice: null, ...over,
});
const kinds = (j: InvoiceJob) => invoiceChoices(j).map((c) => c.kind);
const choice = (j: InvoiceJob, kind: string) => invoiceChoices(j).find((c) => c.kind === kind);

// Completed visits bills the job's lines once for each finished visit, so it's only for a job billed
// by the visit (the database refuses it on any other: 20261113000400).
describe("Completed visits in the Create invoice dialog", () => {
  it("isn't offered on a one-off job billed when it's done, however many visits it has finished", () => {
    expect(kinds(job({ uninvoicedVisits: 3 }))).toEqual(["standard", "deposit", "progress"]);
    expect(firstInvoiceKind(job({ uninvoicedVisits: 3 }))).toBe("standard");
  });

  it("nor once that job has its final invoice", () => {
    const done = job({ uninvoicedVisits: 3, finalInvoice: 12 });
    expect(kinds(done)).toEqual(["standard", "deposit"]);
    expect(choice(done, "standard")?.body).toBe("Already created: invoice #12. Void it to bill the job again.");
  });

  it("is offered on a one-off job invoiced after each visit, while a finished visit waits", () => {
    const perVisit = job({ byVisit: true, uninvoicedVisits: 2 });
    expect(kinds(perVisit)).toEqual(["standard", "visits", "deposit", "progress"]);
    expect(choice(perVisit, "visits")?.body).toBe("2 completed visits aren't invoiced yet.");
    expect(choice(job({ byVisit: true, uninvoicedVisits: 1 }), "visits")?.body).toBe("1 completed visit isn't invoiced yet.");
    expect(kinds(job({ byVisit: true }))).not.toContain("visits");
  });

  it("is what a recurring job billed per visit opens on, and never offered for a fixed price", () => {
    const weekly = job({ kind: "recurring", byVisit: true });
    expect(firstInvoiceKind(weekly)).toBe("visits");
    expect(choice(weekly, "visits")?.body).toBe("No completed visits are waiting to be invoiced.");
    const plan = job({ kind: "recurring", fixed: true, byVisit: false, uninvoicedVisits: 4 });
    expect(firstInvoiceKind(plan)).toBe("standard");
    expect(kinds(plan)).not.toContain("visits");
    expect(choice(plan, "standard")).toEqual({ kind: "standard", title: "The job's price", body: "All the job's line items, once." });
  });

  it("goes by the job's own billing on the job page", () => {
    expect(source("../src/features/jobs/JobPage.tsx")).toContain("byVisit: billsByVisit(j)");
  });
});

// The Client Hub makes the deposit's invoice as the client approves (hub_deposit_invoice), so by the
// time the office opens Create invoice the quote's deposit may already be billed.
describe("the deposit in the Create invoice dialog", () => {
  it("offers what the quote asked for, filled in, until it's invoiced", () => {
    const asked = job({ deposit: 500 });
    expect(choice(asked, "deposit")?.body).toBe("The quote asked for $500.00.");
    expect(startingAmount(asked, "deposit")).toBe("500");
    expect(startingAmount(asked, "progress")).toBe("");
    expect(choice(job(), "deposit")?.body).toBe("Bill an amount up front.");
    expect(startingAmount(job(), "deposit")).toBe("");
  });

  it("says it's already invoiced, with the invoice's number, and fills in no second one", () => {
    const invoiced = job({ deposit: 500, depositInvoice: 41, billed: 500 });
    expect(choice(invoiced, "deposit")?.body).toBe("Deposit already invoiced (#41). Enter an amount only to bill another.");
    expect(startingAmount(invoiced, "deposit")).toBe("");
    // A deposit billed by hand on a job whose quote asked for none reads the same.
    expect(choice(job({ depositInvoice: 7 }), "deposit")?.body).toBe("Deposit already invoiced (#7). Enter an amount only to bill another.");
  });

  it("reads the job's deposit invoice that isn't void on the job page", () => {
    const page = source("../src/features/jobs/JobPage.tsx");
    expect(page).toContain(`const depositInvoice = live.find((i) => i.kind === "deposit")?.number ?? null;`);
    expect(page).toContain("deposit: Number(j.quote?.deposit_amount ?? 0), depositInvoice, billed,");
  });
});

describe("the other choices", () => {
  it("open on retainage or progress once the final invoice is made", () => {
    expect(firstInvoiceKind(job({ finalInvoice: 3, retainageHeld: 50 }))).toBe("retainage");
    expect(firstInvoiceKind(job({ finalInvoice: 3 }))).toBe("progress");
    expect(choice(job({ retainageHeld: 50 }), "retainage")?.body).toBe("Bill the $50.00 held back on earlier invoices.");
  });

  it("say what the final invoice takes off", () => {
    expect(choice(job({ billed: 200 }), "standard")?.body).toBe("All line items, less $200.00 already billed as deposits or progress.");
    expect(choice(job(), "standard")?.body).toBe("All the job's line items.");
  });
});
