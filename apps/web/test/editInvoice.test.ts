/**
 * Edit invoice (features/invoices/editInvoice.ts and EditInvoiceDialog.tsx): which lines an edit
 * takes and which stay, the rows typed and the lines they send, what's said about the result, and
 * when it's offered. The rules themselves are the database's (edit_invoice,
 * 20261113000440_edit_sent_invoices.sql): the screen sends the lines there, preview and save alike.
 */
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { editOffer, editRows, lockedLines, lockedReason, newRow, resultWords, rowsProblem, rowsToLines, type EditResult, type InvoiceLine } from "../src/features/invoices/editInvoice";

const source = (path: string) => readFileSync(new URL(path, import.meta.url), "utf8");

const line = (over: Partial<InvoiceLine> & { id: string }): InvoiceLine => ({ name: "Labor", description: null, quantity: 1, unit: "ea", unit_price: 500, taxable: true, sort: 0, ...over });
const lines: InvoiceLine[] = [
  line({ id: "fee", name: "Late fee", unit_price: 25, taxable: false, sort: 9, kind: "late_fee" }),
  line({ id: "l2", name: "Extra outlet", description: "Garage", quantity: 2.5, unit: "hr", unit_price: 75, sort: 1 }),
  line({ id: "l1", sort: 0 }),
  line({ id: "min", name: "Minimum charge", unit_price: 40, sort: 3, kind: "minimum" }),
  line({ id: "promo", name: "Promo code SPRING", unit_price: -50, sort: 4, discount_quote_id: "q1" }),
  line({ id: "dep", name: "Less deposit (invoice #41)", unit_price: -200, taxable: false, sort: 200001 }),
  line({ id: "prog", name: "Less progress billing (invoice #42)", unit_price: -300, sort: 200002 }),
];

describe("the lines an edit takes", () => {
  it("are the invoice's ordinary lines, in order, ready to type over", () => {
    expect(editRows(lines)).toEqual([
      { key: "l1", id: "l1", name: "Labor", description: "", quantity: "1", unit: "ea", unit_price: "500.00", taxable: true },
      { key: "l2", id: "l2", name: "Extra outlet", description: "Garage", quantity: "2.5", unit: "hr", unit_price: "75.00", taxable: true },
    ]);
  });

  it("leave the late fee, the minimum charge, a promo discount and the job's credits as they are, each with why", () => {
    expect(lockedLines(lines).map(({ line: l, reason }) => [l.id, reason])).toEqual([
      ["min", "The minimum charge stays as it was sent."],
      ["promo", "A promo code's discount stays as it was sent."],
      ["fee", "Use Remove late fee to take it off."],
      ["dep", "It takes off what another of the job's invoices billed."],
      ["prog", "It takes off what another of the job's invoices billed."],
    ]);
  });

  it("go by the same test as the database (private.invoice_line_locked)", () => {
    // A discount typed by hand, or a line that only looks like a credit, is an ordinary line.
    expect(lockedReason({ name: "Loyalty discount", unit_price: -20 })).toBeNull();
    expect(lockedReason({ name: "Less deposit (invoice #41)", unit_price: 200 })).toBeNull();
    expect(lockedReason({ name: "Less deposit", unit_price: -200 })).toBeNull();
    const migration = source("../../../supabase/migrations/20261113000440_edit_sent_invoices.sql");
    expect(migration).toContain("select l.kind is not null or l.discount_quote_id is not null");
    expect(migration).toContain(String.raw`or (l.unit_price < 0 and l.name ~ '^Less (deposit|progress billing) \(invoice #[0-9]+\)$')`);
  });
});

describe("the lines as typed", () => {
  const rows = editRows(lines);

  it("go to the database in order, an existing line by its id and a new one without", () => {
    const added = [...rows, { ...newRow(rows, "n1"), name: " Permit ", unit_price: "100.005", taxable: false }];
    expect(rowsToLines(added)).toEqual([
      { id: "l1", name: "Labor", description: null, quantity: 1, unit: "ea", unit_price: 500, taxable: true },
      { id: "l2", name: "Extra outlet", description: "Garage", quantity: 2.5, unit: "hr", unit_price: 75, taxable: true },
      { name: "Permit", description: null, quantity: 1, unit: "ea", unit_price: 100.01, taxable: false },
    ]);
  });

  it("start a new line taxed as the others are", () => {
    expect(newRow(rows, "n1")).toEqual({ key: "n1", id: null, name: "", description: "", quantity: "1", unit: "ea", unit_price: "", taxable: true });
    expect(newRow(rows.map((r) => ({ ...r, taxable: false })), "n1").taxable).toBe(false);
    expect(newRow([], "n1").taxable).toBe(true);
  });

  it("aren't sent until every line has a name, how many and a price", () => {
    expect(rowsProblem(rows)).toBeNull();
    expect(rowsProblem([...rows, newRow(rows, "n1")])).toBe("Give every line a name.");
    expect(rowsProblem([{ ...rows[0]!, quantity: "" }])).toBe("Enter how many for every line.");
    expect(rowsProblem([{ ...rows[0]!, unit_price: "" }])).toBe("Enter a price for every line.");
    expect(rowsProblem([{ ...rows[0]!, unit_price: "-" }])).toBe("Enter a price for every line.");
    // A credit typed as a negative price is a line like any other.
    expect(rowsProblem([{ ...rows[0]!, unit_price: "-50" }])).toBeNull();
  });

  it("can't all be removed, unless lines that stay are left", () => {
    expect(rowsProblem([])).toBe("An invoice needs at least one line.");
    expect(rowsProblem([], 1)).toBeNull();
  });
});

describe("what the edit screen says the invoice comes to", () => {
  const result = (over: Partial<EditResult>): EditResult => ({ status: "partially_paid", total: 650, amount_paid: 300, balance_due: 350, changed: 1, old_total: 500, old_status: "partially_paid", ...over });

  it("is the database's figures: the new total, what it was, what's paid and what's left", () => {
    expect(resultWords(result({}))).toBe("Total $650.00 (was $500.00) · $300.00 paid · $350.00 to pay");
    expect(resultWords(result({ total: 500, balance_due: 200 }))).toBe("Total $500.00 · $300.00 paid · $200.00 to pay");
    expect(resultWords(result({ amount_paid: 0, balance_due: 650, status: "sent", old_status: "sent" }))).toBe("Total $650.00 (was $500.00) · $650.00 to pay");
  });

  it("says when the change pays it off, or makes a paid invoice owe again", () => {
    expect(resultWords(result({ status: "paid", total: 300, balance_due: 0 }))).toBe("Total $300.00 (was $500.00) · $300.00 paid · paid in full");
    expect(resultWords(result({ status: "overdue", old_status: "paid", total: 620, amount_paid: 500, balance_due: 120 }))).toBe("Total $620.00 (was $500.00) · $500.00 paid · $120.00 now owed");
    expect(resultWords(result({ status: "paid", old_status: "paid", total: 500, old_total: 500, amount_paid: 500, balance_due: 0 }))).toBe("Total $500.00 · $500.00 paid");
  });
});

describe("when Edit invoice is offered", () => {
  const free = { fromStripe: false, charging: false, bankOnItsWay: false };

  it("is on any sent invoice, whatever has been paid on it", () => {
    for (const status of ["sent", "partially_paid", "paid", "overdue"]) expect(editOffer({ status }, free), status).toEqual({ offered: true, waits: null });
  });

  it("isn't on a draft (edited on the page), or a void, written-off or Stripe-made invoice", () => {
    for (const status of ["draft", "void", "written_off"]) expect(editOffer({ status }, free).offered, status).toBe(false);
    expect(editOffer({ status: "paid" }, { ...free, fromStripe: true })).toEqual({ offered: false, waits: null });
  });

  it("waits, and says why, while the client is paying the amount as it stands", () => {
    expect(editOffer({ status: "sent" }, { ...free, charging: true })).toEqual({ offered: true, waits: "The card is being charged right now. Try again in a few minutes." });
    expect(editOffer({ status: "overdue" }, { ...free, bankOnItsWay: true })).toEqual({ offered: true, waits: "A bank payment for this invoice is on its way. Edit it once that clears or bounces." });
  });
});

describe("the edit screen and the invoice page", () => {
  const dialog = source("../src/features/invoices/EditInvoiceDialog.tsx");
  const page = source("../src/features/invoices/InvoicePage.tsx");

  it("previews and saves through the one database function, with the copy it opened", () => {
    expect(dialog).toContain(`supabase().rpc("edit_invoice", { p_invoice: invoice.id, p_lines: JSON.parse(preview ? asked! : typed!), p_preview: preview, p_updated_at: opened.updatedAt })`);
    // Nothing is written to the lines or the payments from the screen itself.
    expect(dialog).not.toMatch(/from\("(invoice_line_items|payments|invoices)"\)/);
    // The figures shown are the preview's, never added up in the browser.
    expect(dialog).toContain("{result ? resultWords(result) : refusal ? \"\" : \"Working out the total…\"}");
    expect(dialog).not.toContain("lineTotal");
  });

  it("can't be saved while the database refuses the lines, before it has answered, or with nothing changed", () => {
    expect(dialog).toContain("disabled={Boolean(refusal) || !settled || unchanged}");
    expect(dialog).toContain("if (!refusal && settled && !unchanged) save.mutate();");
  });

  it("says why, with nothing to type in, when the database won't take the invoice as it stands", () => {
    // A deposit or progress invoice the job's final invoice has taken off, or one changed since the page loaded.
    expect(dialog).toContain("const closed = typed === first && asked === first && preview.error ? preview.error : null;");
    expect(dialog).toContain(`description="This invoice can't be edited as it stands."`);
  });

  it("is offered from the menu and under the lines of a sent invoice, with its payments left alone", () => {
    expect(page).toContain(`{ label: "Edit invoice", icon: "edit", hidden: !editing.offered, disabled: Boolean(editing.waits), title: editing.waits ?? undefined, onSelect: () => setDialog("edit") },`);
    expect(page).toContain(`const editing = editOffer(inv, { fromStripe, charging, bankOnItsWay: Boolean(bank) || clearing });`);
    expect(page).toContain(`{dialog === "edit" && <EditInvoiceDialog invoice={{ id: inv.id, number: inv.number, updated_at: inv.updated_at, lines: inv.lines }} onClose={() => setDialog(null)} onSaved={refresh} />}`);
    // The draft's own line editor is still only for a draft.
    expect(page).toContain("const editable = draft && !charging;");
  });
});
