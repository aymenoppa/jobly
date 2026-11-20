/**
 * Finance → Profit's list of the expenses saved without a job (finance/CostsWithoutJob.tsx): what
 * the card says about them, and what each row says. Before it, an expense saved with its Job # left
 * empty was shown nowhere again.
 */
import { describe, expect, it } from "vitest";
import { looseDetail, looseSummary } from "@/features/finance/CostsWithoutJob";

describe("costs that aren't on a job", () => {
  it("says how many there are, what they come to, and how many are still to reimburse", () => {
    expect(looseSummary([])).toBe("Fuel, tools and other costs saved without a job");
    expect(looseSummary([{ amount: 61.4, reimbursable: true, reimbursed_at: null }])).toBe("1 cost · $61.40 · 1 to reimburse");
    expect(looseSummary([
      { amount: 61.4, reimbursable: true, reimbursed_at: "2026-11-02T10:00:00Z" },
      { amount: 0.1, reimbursable: false, reimbursed_at: null },
      { amount: 0.2, reimbursable: true, reimbursed_at: null },
    ])).toBe("3 costs · $61.70 · 1 to reimburse");
    expect(looseSummary([{ amount: 20, reimbursable: false, reimbursed_at: null }, { amount: 30, reimbursable: false, reimbursed_at: null }])).toBe("2 costs · $50.00");
  });

  it("says what each one is: its category, description and date, and whether it's owed back", () => {
    expect(looseDetail({ category: "Fuel", description: "Truck 2", incurred_on: "2026-11-03", reimbursable: true, reimbursed_at: null })).toBe("Fuel · Truck 2 · Nov 3, 2026 · to reimburse");
    expect(looseDetail({ category: "Supplies", description: null, incurred_on: "2026-11-03", reimbursable: true, reimbursed_at: "2026-11-05T09:00:00Z" })).toBe("Supplies · Nov 3, 2026 · reimbursed");
    expect(looseDetail({ category: null, description: null, incurred_on: "2026-11-03", reimbursable: false, reimbursed_at: null })).toBe("Nov 3, 2026");
  });
});
