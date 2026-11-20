/**
 * Change prices on the Jobs page (features/jobs/ChangePricesDialog.tsx): who is offered it, that it
 * previews before it applies and sends what was previewed, a group of jobs at a time under one id,
 * and what it tells the office. The figures and the rules are the database's
 * (supabase/tests/price_changes_test.sql); what's built from them is core priceChange.
 */
import { memberPermissions, ROLES, type Role } from "@jobly/core/roles";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { partlyApplied } from "../src/features/jobs/ChangePricesDialog";
import { can, hasRole } from "../src/lib/session";

const source = (file: string) => readFileSync(fileURLToPath(new URL(file, import.meta.url)), "utf8");
const dialog = source("../src/features/jobs/ChangePricesDialog.tsx");
const page = source("../src/features/jobs/JobsPage.tsx");
const member = (role: Role, custom?: string[]) => ({ role, permissions: memberPermissions(role, custom) });

describe("who is offered Change prices", () => {
  const offered = (who: ReturnType<typeof member>) => hasRole(who, "admin", "office") && can(who, "sales");

  it("owners, admins and the office with Quotes and sales, as the database decides", () => {
    expect(page).toContain('const canChangePrices = hasRole(session, "admin", "office") && can(session, "sales");');
    expect(page).toContain("{canChangePrices && <Button icon=\"dollar\" onClick={() => setPricing(true)}>Change prices</Button>}");
    expect(ROLES.filter((role) => offered(member(role)))).toEqual(["owner", "admin", "office"]);
    expect(offered(member("office", ["schedule", "invoices"]))).toBe(false);
    expect(offered(member("estimator", ["sales"]))).toBe(false);
  });

  it("with the jobs ticked on the list to start from", () => {
    expect(page).toContain("<ChangePricesDialog picked={selection.ids}");
  });
});

describe("previewing, then applying what was previewed", () => {
  it("asks the database for the preview and changes nothing until Change prices is pressed", () => {
    expect(dialog).toContain('rpc("price_change_preview", { p_company: company.id, p_change: change as unknown as Json })');
    // Apply is only there once a preview is on screen, and any edit to the form takes the preview away.
    expect(dialog).toContain("{shown && totals && (");
    expect(dialog).toMatch(/const edit = [\s\S]*?setShown\(null\);/);
  });

  it("sends the previewed lines a group of jobs at a time, all under one change id, so the whole change can be undone", () => {
    expect(dialog).toContain("const groups = priceChangeGroups(shown!.preview.jobs, only);");
    expect(dialog).toMatch(/const id = crypto\.randomUUID\(\);\s+let changed = 0;\s+for \(const group of groups\)/);
    expect(dialog).toContain('rpc("apply_price_change", { p_company: company.id, p_id: id, p_change: shown!.change as unknown as Json, p_lines: group.lines as unknown as Json })');
  });

  it("says how far it got when a later group is turned down", () => {
    expect(partlyApplied(100, 150, "Something changed since the preview (job #212). Preview again, then apply")).toBe(
      "Prices changed on 100 of 150 jobs. The rest weren't changed: Something changed since the preview (job #212). Preview again, then apply",
    );
  });

  it("downloads the preview as a CSV of the jobs still ticked", () => {
    expect(dialog).toContain("toCsv(priceChangeRows(shown.preview.jobs, only), [...PRICE_CHANGE_COLUMNS])");
  });
});

describe("what the dialog tells the office", () => {
  it("that it changes invoices made from now on, nothing already invoiced, and sends clients nothing", () => {
    expect(dialog).toContain("Invoices made from now on use the new prices. Nothing already invoiced changes, and nothing is sent to clients.");
    expect(dialog).toContain("Lines at $0, discounts and one-time extra work on a visit aren't changed.");
    expect(dialog).toContain("One-off jobs keep their prices.");
  });

  it("offers Undo on an earlier change until an invoice was made at the new prices, and says which", () => {
    expect(dialog).toContain("{!h.undone_at && !h.invoice && <Button size=\"sm\" icon=\"undo\"");
    expect(dialog).toContain("can't be undone: invoice #${h.invoice} was made at the new prices");
    expect(dialog).toContain('rpc("undo_price_change", { p_company: company.id, p_id: change.id })');
  });

  it("sends no email or text: nothing here calls the server's send routes", () => {
    expect(dialog).not.toMatch(/api\.(post|patch|put)\(/);
  });
});
