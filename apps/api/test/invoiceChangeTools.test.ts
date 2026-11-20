/**
 * The assistant's tools that change an invoice after it's sent (assistant-tools/invoices.ts). Each
 * goes through the database's own function for it, so an assistant is held to the rules the invoice
 * page is: edit_invoice_lines (edit_invoice, 20261113000440_edit_sent_invoices.sql), remove_late_fee
 * (20261113000420_late_fee_off_for_an_invoice.sql), and update_invoice's no_late_fee.
 */
import { createClient } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { invoiceTools } from "../src/assistant-tools/invoices";
import type { ToolContext } from "../src/assistant-tools/tool";

const INVOICE = "11111111-1111-4111-8111-111111111111";

/** The Data API with one sent invoice. `rpc` answers the database's functions by name; what's sent is kept. */
function database(rpc: Record<string, () => Response> = {}, invoice: Record<string, unknown> | null = { id: INVOICE, number: 1042, status: "overdue", total: 200, balance_due: 200, no_late_fee: true }) {
  const sent: Array<{ method: string; path: string; body: unknown }> = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input instanceof Request ? input.url : input));
    const method = init?.method ?? "GET";
    const table = url.pathname.replace("/rest/v1/", "");
    sent.push({ method, path: `${table}?${decodeURIComponent(url.search)}`, body: typeof init?.body === "string" ? JSON.parse(init.body) : null });
    const single = String(new Headers(init?.headers).get("accept")).includes("vnd.pgrst.object");
    if (table.startsWith("rpc/")) return rpc[table.slice(4)]?.() ?? Response.json(null);
    if (table === "custom_field_definitions") return Response.json([]);
    const rows = table === "invoices" && invoice ? [invoice] : [];
    return Response.json(single ? rows[0] ?? null : rows);
  });
  const ctx = { db: createClient("http://127.0.0.1:8080", "sb_publishable_test"), companyId: "company-1", timezone: "America/New_York" } as unknown as ToolContext;
  return { sent, ctx };
}
const refusal = (message: string, code = "22023") => () => Response.json({ code, message, details: null, hint: null }, { status: 400 });

afterEach(() => vi.unstubAllGlobals());

describe("the assistant editing a sent invoice's lines", () => {
  const LINE = "22222222-2222-4222-8222-222222222222";
  const after = { id: INVOICE, status: "partially_paid", total: 650, amount_paid: 300, balance_due: 350, changed: 1, old_total: 500, old_status: "partially_paid" };

  it("goes through the database's edit_invoice, the one path the invoice page's Edit invoice takes", async () => {
    const { ctx, sent } = database({ edit_invoice: () => Response.json(after) });
    const args = invoiceTools.edit_invoice_lines.input.parse({
      invoice_id: INVOICE,
      lines: [{ id: LINE, name: " Labor ", quantity: 1, unit_price: 500 }, { name: "Extra outlet", description: "Garage", quantity: 2, unit_price: 75.004, taxable: false }],
    });
    expect(await invoiceTools.edit_invoice_lines.run(ctx, args)).toEqual({ saved: true, invoice: after });
    expect(sent.find((s) => s.path.startsWith("rpc/edit_invoice"))?.body).toEqual({
      p_invoice: INVOICE,
      p_preview: false,
      p_lines: [
        { id: LINE, name: "Labor", description: null, quantity: 1, unit: "ea", unit_price: 500, taxable: true },
        { name: "Extra outlet", description: "Garage", quantity: 2, unit: "ea", unit_price: 75, taxable: false },
      ],
    });
    // Nothing is written to the invoice's lines or payments by the tool itself.
    expect(sent.filter((s) => s.method !== "GET").map((s) => s.path.split("?")[0])).toEqual(["rpc/edit_invoice"]);
    expect(invoiceTools.edit_invoice_lines.area).toBe("invoices");
    expect(invoiceTools.edit_invoice_lines.destructive).toBeUndefined();
  });

  it("can ask what the change would come to without making it", async () => {
    const { ctx, sent } = database({ edit_invoice: () => Response.json(after) });
    const result = await invoiceTools.edit_invoice_lines.run(ctx, invoiceTools.edit_invoice_lines.input.parse({ invoice_id: INVOICE, lines: [{ name: "Labor", unit_price: 650 }], preview: true }));
    expect(result).toEqual({ preview: true, invoice: after });
    expect((sent.find((s) => s.path.startsWith("rpc/edit_invoice"))?.body as { p_preview: boolean }).p_preview).toBe(true);
  });

  it("passes on the database's refusals as they read", async () => {
    for (const message of [
      "This invoice has $300.00 paid on it, so its total can't go below that. Refund the difference first.",
      "Undo the write-off before changing this invoice",
      "This invoice was made in Stripe. Make changes there",
      "Invoice #12 already takes this one off the job's total. Void that invoice to change this one",
    ]) {
      const { ctx } = database({ edit_invoice: refusal(message) });
      await expect(invoiceTools.edit_invoice_lines.run(ctx, invoiceTools.edit_invoice_lines.input.parse({ invoice_id: INVOICE, lines: [{ name: "Labor", unit_price: 1 }] }))).rejects.toThrow(message);
    }
  });

  it("never reaches another company's invoice, and takes no line without a name", async () => {
    const { ctx, sent } = database({ edit_invoice: () => Response.json(after) }, null);
    await expect(invoiceTools.edit_invoice_lines.run(ctx, invoiceTools.edit_invoice_lines.input.parse({ invoice_id: INVOICE, lines: [{ name: "Labor", unit_price: 1 }] }))).rejects.toThrow();
    expect(sent.some((s) => s.path.startsWith("rpc/"))).toBe(false);
    expect(invoiceTools.edit_invoice_lines.input.safeParse({ invoice_id: INVOICE, lines: [{ name: "  ", unit_price: 1 }] }).success).toBe(false);
  });

  it("is told each line's id by get_invoice", async () => {
    const { ctx, sent } = database();
    await invoiceTools.get_invoice.run(ctx, { invoice_id: INVOICE });
    expect(sent[0]!.path).toMatch(/lines:invoice_line_items\(id,/);
  });
});

describe("the assistant taking a late fee off", () => {
  it("calls the database's remove_late_fee for this company's invoice, and says what came off", async () => {
    const { ctx, sent } = database({ remove_late_fee: () => Response.json(25) });
    const result = await invoiceTools.remove_late_fee.run(ctx, invoiceTools.remove_late_fee.input.parse({ invoice_id: INVOICE }));
    expect(result).toEqual({ removed: 25, invoice: { id: INVOICE, number: 1042, status: "overdue", total: 200, balance_due: 200, no_late_fee: true } });
    // The invoice is looked up in the company first.
    expect(sent[0]!.path).toContain("company_id=eq.company-1");
    expect(sent.find((s) => s.path.startsWith("rpc/remove_late_fee"))?.body).toEqual({ p_invoice: INVOICE });
    expect(invoiceTools.remove_late_fee.area).toBe("invoices");
  });

  it("passes on why the database refused", async () => {
    const paid = "This invoice has $225.00 paid on it, so its total can't go below that. Refund the difference first.";
    const { ctx } = database({ remove_late_fee: refusal(paid) });
    await expect(invoiceTools.remove_late_fee.run(ctx, { invoice_id: INVOICE })).rejects.toThrow(paid);
  });

  it("never reaches another company's invoice", async () => {
    const { ctx, sent } = database({ remove_late_fee: () => Response.json(25) }, null);
    await expect(invoiceTools.remove_late_fee.run(ctx, { invoice_id: INVOICE })).rejects.toThrow();
    expect(sent.some((s) => s.path.startsWith("rpc/"))).toBe(false);
  });
});

describe("the assistant turning late fees off for an invoice", () => {
  it("saves no_late_fee with update_invoice, with or without custom fields", async () => {
    const { ctx, sent } = database();
    expect(await invoiceTools.update_invoice.run(ctx, invoiceTools.update_invoice.input.parse({ invoice_id: INVOICE, no_late_fee: true }))).toEqual({ saved: true, custom_fields: null, no_late_fee: true });
    const patch = sent.find((s) => s.method === "PATCH" && s.path.startsWith("invoices"));
    expect(patch?.body).toEqual({ no_late_fee: true });
    expect(patch?.path).toContain("company_id=eq.company-1");
  });

  it("asks for something to change", async () => {
    const { ctx, sent } = database();
    await expect(invoiceTools.update_invoice.run(ctx, invoiceTools.update_invoice.input.parse({ invoice_id: INVOICE }))).rejects.toThrow("Give the custom fields to change, or no_late_fee.");
    expect(sent.some((s) => s.method === "PATCH")).toBe(false);
  });
});
