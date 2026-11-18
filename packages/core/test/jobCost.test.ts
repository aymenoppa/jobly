/**
 * jobCost (reports.ts): the one calculation the job page, Finance → Profit and Services, AI
 * assistants and job profit alerts all use. Each screen's own expectations are checked against it
 * here, so a change to one is a change to all of them; and the alert's decision.
 */
import { describe, expect, it } from "vitest";
import { belowProfitLine, jobCost, jobProfit, laborCost, profitAlertDecision, profitAlertPercent, profitAlertText, serviceFigures, type ServiceItem } from "../src";

const lines = [{ quantity: 27, unit_cost: 180, unit_labor_cost: 70 }, { quantity: 1, unit_cost: 50, unit_labor_cost: null }];

describe("a job's costs", () => {
  it("counts the whole line cost while the job has no labor of its own", () => {
    expect(jobCost({ price: 10000, lines, labor: 0, crewPay: [], expenses: [{ amount: 100 }] })).toMatchObject({
      materials: 4910, left_out: 0, crew: 0, expenses: 100, cost: 5010, profit: 4990, margin: 49.9, actual_labor: false, has_actual_costs: true,
    });
  });

  it("counts materials only once there's sub and crew pay or time at a rate", () => {
    expect(jobCost({ price: 10000, lines, labor: 0, crewPay: [{ amount: "2025.00" }], expenses: [{ amount: 100 }] })).toMatchObject({ materials: 3020, left_out: 1890, crew: 2025, cost: 5145, profit: 4855 });
    expect(jobCost({ price: 0, lines, labor: 300, crewPay: [], expenses: [] })).toMatchObject({ materials: 3020, margin: null, actual_labor: true });
  });

  it("adds extra work on visits to the price and costs its lines as the job's", () => {
    const c = jobCost({ price: 45, lines: [{ quantity: 1, unit_cost: 20 }], labor: 0, crewPay: [], expenses: [], extras: { price: 120, lines: [{ quantity: 2, unit_cost: 25 }] } });
    expect(c).toMatchObject({ price: 165, extras: 120, materials: 70, profit: 95 });
    expect(Math.round(c.margin!)).toBe(58);
  });

  it("counts logged materials in place of the estimate and leaves out expenses already in the lines", () => {
    const byTon = [{ quantity: 40, unit_cost: 92, unit_labor_cost: null, service_id: "hot", unit: "ton" }];
    const c = jobCost({ price: 5720, lines: byTon, labor: 0, crewPay: [], expenses: [{ amount: "3795.00", in_line_costs: true }, { amount: 120 }], logged: [{ service_id: "hot", name: "Hot-mix", unit: "ton", quantity: 44 }] });
    expect(c).toMatchObject({ materials: 4048, material_adjustment: 368, expenses: 120, expenses_in_lines: 3795, cost: 4168 });
  });

  it("says nothing has been spent while there are only the lines' estimates", () => {
    expect(jobCost({ price: 10000, lines, labor: 0, crewPay: [], expenses: [] }).has_actual_costs).toBe(false);
    expect(jobCost({ price: 10000, lines, labor: 0, crewPay: [], expenses: [], logged: [{ name: "Stone", unit: "ton", quantity: 1 }] }).has_actual_costs).toBe(true);
  });

  it("costs time at each entry's rate, and a running clock at nothing", () => {
    const time = [
      { id: "a", job_id: "j", started_at: "2026-10-05T12:00:00Z", ended_at: "2026-10-05T20:00:00Z" },
      { id: "b", job_id: "j", started_at: "2026-10-06T12:00:00Z", ended_at: null },
    ];
    expect(laborCost(time, (t) => (t.id === "a" ? 25 : 40))).toBe(200);
  });

  it("is what Finance → Profit and AI assistants report for each job", () => {
    const job = { id: "j1", number: 4, title: "Drive", financials: { contract_total: 10000 }, lines };
    const time = [{ id: "t", job_id: "j1", started_at: "2026-10-05T12:00:00Z", ended_at: "2026-10-05T14:00:00Z" }];
    const own = jobCost({ price: 10000, lines, labor: laborCost(time, () => 50), crewPay: [{ amount: 300 }], expenses: [{ amount: 75 }] });
    const reported = jobProfit([job], time, [{ job_id: "j1", amount: 75 }, { job_id: "j2", amount: 999 }], () => 50, null, [{ job_id: "j1", amount: 300 }]).jobs[0]!;
    expect(reported).toMatchObject({ labor: own.labor, crew_pay: own.crew, materials: own.materials, cost: own.cost, profit: own.profit, margin_percent: Math.round(own.margin! * 10) / 10 });
  });

  it("gives Services each job's labor, pay and expenses as it gives the job page", () => {
    const items: ServiceItem[] = [{ id: "s1", name: "Sealcoat", category: null, unit_cost: 0, labor_cost: null }];
    const sold = [{ service_id: "s1", name: "Sealcoat", quantity: 1, unit_price: 1000, invoice: { id: "i", job_id: "j1", kind: "standard", status: "sent", issued_on: "2026-10-05", discount_amount: 0, credit_amount: 0 } }];
    const time = [{ id: "t", job_id: "j1", started_at: "2026-10-05T12:00:00Z", ended_at: "2026-10-05T14:00:00Z" }];
    const figures = serviceFigures(sold, items, { jobLines: sold, time, expenses: [{ job_id: "j1", amount: 40 }, { job_id: "j1", amount: 500, in_line_costs: true }], rateOf: () => 30, crewPay: [{ job_id: "j1", amount: 100 }] });
    const own = jobCost({ price: 0, lines: [], labor: 60, crewPay: [{ amount: 100 }], expenses: [{ amount: 40 }, { amount: 500, in_line_costs: true }] });
    expect(figures.services[0]).toMatchObject({ labor: own.labor + own.crew, expenses: own.expenses });
  });
});

describe("job profit alerts", () => {
  const cost = (margin: number | null, more: Partial<{ price: number; has_actual_costs: boolean }> = {}) => ({ price: 1000, margin, has_actual_costs: true, ...more });

  it("reads the company's line, off unless it's a whole percent from 1 to 99", () => {
    expect(profitAlertPercent({ profit_alert_percent: 20 })).toBe(20);
    expect(profitAlertPercent({ profit_alert_percent: "15" })).toBe(15);
    for (const off of [null, 0, 100, 12.5, "x", undefined]) expect(profitAlertPercent({ profit_alert_percent: off })).toBeNull();
    expect(profitAlertPercent(null)).toBeNull();
  });

  it("puts a one-off job below the line by its margin as the job page rounds it", () => {
    expect(belowProfitLine({ kind: "one_off" }, cost(8), 20)).toBe(true);
    expect(belowProfitLine({ kind: "one_off" }, cost(19.4), 20)).toBe(true);
    // Shown as 20%: not below 20%.
    expect(belowProfitLine({ kind: "one_off" }, cost(19.6), 20)).toBe(false);
    expect(belowProfitLine({ kind: "one_off" }, cost(-40), 20)).toBe(true);
  });

  it("leaves out repeating jobs, jobs with no price or nothing spent yet, and a company with it off", () => {
    expect(belowProfitLine({ kind: "recurring" }, cost(5), 20)).toBe(false);
    expect(belowProfitLine({ kind: "one_off" }, cost(null, { price: 0 }), 20)).toBe(false);
    expect(belowProfitLine({ kind: "one_off" }, cost(5, { has_actual_costs: false }), 20)).toBe(false);
    expect(belowProfitLine({ kind: "one_off" }, cost(5), null)).toBe(false);
  });

  it("tells the office once as a job goes below, and again only after it came back up", () => {
    expect(profitAlertDecision(false, true, false)).toEqual({ below: true, tell: true });
    expect(profitAlertDecision(true, true, false)).toEqual({ below: true, tell: false });
    expect(profitAlertDecision(true, false, false)).toEqual({ below: false, tell: false });
    expect(profitAlertDecision(false, true, false).tell).toBe(true);
  });

  it("only lists the jobs already below right after the line changes", () => {
    expect(profitAlertDecision(false, true, true)).toEqual({ below: true, tell: false });
  });

  it("says which job, whose, and by how much", () => {
    expect(profitAlertText({ number: 12, client: "Maria Lopez" }, 8.4, 20)).toBe("Job #12 for Maria Lopez is at 8% profit, below your 20%");
    expect(profitAlertText({ number: 3, client: null }, -12, 25)).toBe("Job #3 is at -12% profit, below your 25%");
  });
});
