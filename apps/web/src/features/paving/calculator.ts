/**
 * The paving calculator (Paving → Calculator): a paving bid on one page, the way a paver works it
 * out on paper. The area goes in; each item's amount comes from the area and its depth or spread
 * rate, or is typed straight in (days, feet); times its price; plus profit, and up to the business's
 * minimum charge for a small job.
 *
 * What it prices is the business's own setup (companies.settings.paving_calculator, Paving →
 * Calculator → Set up): its items, each figured one of the ways in BASES, its job types, how it
 * takes profit and what it adds for waste. A paver who calls base stone "crusher run", prices
 * sealcoat by the square foot or takes 20% on cost sets it up that way; DEFAULT_SETUP is a working
 * paver's sheet to start from. A job's worksheet (public.paving_worksheets) keeps the setup it was
 * priced with, so a price changed later never changes an old bid.
 */
import { lineTotal, toCents } from "@jobly/core/money";
import { isPavingWork, type LinePart, type PavingWork } from "@jobly/core/paving";

/** How an item's amount is figured. Tons and gallons come from the area, trucking from the tons; the rest are typed. */
export const BASES = {
  depth: { label: "Tons, by depth", unit: "ton", per: "in deep", material: true },
  spread_lb: { label: "Tons, by pounds per sq yd", unit: "ton", per: "lb per sq yd", material: true },
  spread_gal: { label: "Gallons, by gallons per sq yd", unit: "gal", per: "gal per sq yd", material: true },
  area_sqyd: { label: "The whole area, per sq yd", unit: "sq yd", per: null, material: false },
  area_sqft: { label: "The whole area, per sq ft", unit: "sq ft", per: null, material: false },
  haul: { label: "Per ton hauled (every ton on the job)", unit: "ton", per: null, material: false },
  length: { label: "By the foot", unit: "ft", per: null, material: false },
  days: { label: "By the day", unit: "day", per: null, material: false },
  count: { label: "Each", unit: "ea", per: null, material: false },
  flat: { label: "Once per job", unit: "ea", per: null, material: false },
} as const;
export type Basis = keyof typeof BASES;
export const BASIS_IDS = Object.keys(BASES) as Basis[];
const AREA_PICKS: readonly Basis[] = ["depth", "spread_lb", "spread_gal", "area_sqyd", "area_sqft"];
/** Picked for each job from the area (a depth, a rate, on or off): what a job type sets. */
export const fromArea = (basis: Basis) => AREA_PICKS.includes(basis);
/** Worked out by the calculator (from the area, or trucking from the tons), so it can be typed over. */
export const workedOut = (basis: Basis) => fromArea(basis) || basis === "haul";
/** On for a new job when it has a price: trucking and mobilization, which most jobs take. */
const onByDefault = (item: CalcItem) => (item.basis === "haul" || item.basis === "flat") && item.price > 0;

/**
 * Hot-mix asphalt and compacted crushed stone base both weigh about 110 lb per sq yd for each inch
 * of depth. For asphalt it's the usual estimating figure (about 147 lb per cu ft in place); for
 * dense-graded base stone it's the 2 tons a compacted cubic yard that stone is commonly ordered by
 * (4,000 lb over 36 sq yd-inches is 111). The Paving preset's "Hot-mix asphalt tons", "Stone base
 * tons" and "Gravel tons" formulas use the same 110 (packages/core/src/presets/paving.json), so a
 * quote from the price list and one from this calculator order the same stone. A business that
 * buys lighter or heavier stone sets its own weight on the item in Set up.
 */
export const DEFAULT_WEIGHT = 110;
const LB_PER_TON = 2000;

/** A ready-made value for the item's dropdown (a depth, a spread rate), with its own price if it has one. */
export interface Choice {
  label: string;
  value: number;
  price?: number;
}

export interface CalcItem {
  id: string;
  name: string;
  /** The heading it's under on the calculator and the worksheet. */
  section: string;
  basis: Basis;
  /** Per unit (BASES[basis].unit), before profit. */
  price: number;
  /** Depth only: pounds per sq yd for each inch. */
  weight?: number;
  choices?: Choice[];
  /** Days only: a day the crew is out, which profit by the day counts. */
  crew?: boolean;
  /**
   * The kind of work it is (PAVING_WORK), which weather rules and checklists go by on a job priced
   * here. null: none, said outright. Left out of a setup saved before kinds, it's worked out from
   * the standard items (STANDARD_WORK).
   */
  work?: PavingWork | null;
}

/** A kind of job: the depths and rates (by item id) it usually takes. */
export interface JobType {
  id: string;
  name: string;
  values: Record<string, number>;
}

export type ProfitBy = "day" | "percent" | "none";
export interface Profit {
  by: ProfitBy;
  /** Per day, or a percent of the cost. */
  amount: number;
}

export interface CalcSetup {
  items: CalcItem[];
  jobs: JobType[];
  profit: Profit;
  /** Percent added to tons and gallons before they're rounded up. */
  waste: number;
  /** The least a job is priced at (0: none). */
  minimum: number;
}

/**
 * Until a business sets up its own: a working paver's sheet. A 0 price is one nobody has set yet.
 * Stone and emulsion go by different numbers from one state to the next (21A, #8, #68 and CRS-2 are
 * one region's), so each is called what it is, with that region's code beside it.
 */
export const DEFAULT_SETUP: CalcSetup = {
  items: [
    { id: "top", name: "Top coat asphalt", section: "Asphalt", basis: "depth", price: 100, weight: DEFAULT_WEIGHT, work: "asphalt" },
    { id: "intermediate", name: "Intermediate asphalt", section: "Asphalt", basis: "depth", price: 92, weight: DEFAULT_WEIGHT, work: "asphalt" },
    { id: "base", name: "Base asphalt", section: "Asphalt", basis: "depth", price: 91, weight: DEFAULT_WEIGHT, work: "asphalt" },
    { id: "stone21a", name: "Crusher run base stone (21A)", section: "Stone and tar", basis: "depth", price: 30, weight: DEFAULT_WEIGHT, work: "stone" },
    { id: "stone8", name: "Chip stone, 3/8 inch (#8), top layer", section: "Stone and tar", basis: "spread_lb", price: 30, work: "tar_chip" },
    { id: "stone68", name: "Chip stone, 3/4 inch (#68), prime coat", section: "Stone and tar", basis: "spread_lb", price: 31 },
    {
      id: "liquid",
      name: "Liquid asphalt emulsion (CRS-2)",
      section: "Stone and tar",
      basis: "spread_gal",
      price: 4.5,
      choices: [{ label: "Tack coat", value: 0.1 }, { label: "Over existing tar", value: 0.3 }, { label: "New tar", value: 0.4 }],
    },
    {
      id: "mill",
      name: "Milling",
      section: "Milling and prep",
      basis: "area_sqyd",
      price: 0,
      choices: [{ label: '1"', value: 1, price: 0 }, { label: '1.5"', value: 1.5, price: 5 }, { label: '2"', value: 2, price: 6 }, { label: '3"', value: 3, price: 0 }, { label: '4"', value: 4, price: 0 }],
      work: "milling",
    },
    { id: "fabric", name: "Fabric", section: "Milling and prep", basis: "area_sqyd", price: 2.75 },
    { id: "sawCut", name: "Saw cutting", section: "Milling and prep", basis: "length", price: 0 },
    { id: "fullCrew", name: "Full crew", section: "Crew and trucks", basis: "days", price: 5000, crew: true },
    { id: "halfCrew", name: "Half crew", section: "Crew and trucks", basis: "days", price: 2500, crew: true },
    { id: "truck", name: "Truck hire", section: "Crew and trucks", basis: "days", price: 800 },
    { id: "trucking", name: "Trucking", section: "Crew and trucks", basis: "haul", price: 0 },
    { id: "mobilization", name: "Mobilization", section: "Crew and trucks", basis: "flat", price: 0 },
  ],
  jobs: [
    { id: "overlay", name: "Mill and overlay", values: { mill: 2, liquid: 0.1, top: 2 } },
    { id: "pave", name: "New asphalt paving", values: { stone21a: 8, top: 2 } },
    { id: "chip", name: "Tar and chip", values: { liquid: 0.4, stone8: 35 } },
    { id: "gravel", name: "Gravel", values: { stone21a: 8 } },
  ],
  profit: { by: "day", amount: 7000 },
  waste: 0,
  minimum: 0,
};

/**
 * The kind of work each standard item is, for a setup saved before items said: an item still figured
 * the way the standard one is takes its kind. Anything a business added or changed has none until
 * they pick one in Set up.
 */
const STANDARD_WORK = new Map(DEFAULT_SETUP.items.flatMap((i) => (i.work ? [[i.id, { basis: i.basis, work: i.work }] as const] : [])));

export interface Side {
  length: number;
  width: number;
}

/** One job's choices: the area, each item's depth, rate, days or count, and its profit. */
export interface CalcInput {
  job: string | null;
  sqft: number;
  /** The area as length × width pieces, when it was entered that way. */
  sides: Side[] | null;
  values: Record<string, number>;
  profit: Profit;
  /** Profit days typed over; otherwise the crew days. */
  profitDays: number | null;
  /** The least this job is priced at (0: none). */
  minimum: number;
}

/** Amounts typed over the worked-out ones, by item id. */
export type Overrides = Record<string, number>;

/** A job's worksheet as public.paving_worksheets.data keeps it. */
export interface WorksheetData {
  v: 1;
  setup: CalcSetup;
  input: CalcInput;
  overrides: Overrides;
}

export interface CalcLine {
  item: CalcItem;
  /** What the amount is figured from: inches, a spread rate, 1 for "on", days, feet or a count. */
  value: number;
  unit: string;
  /** What the calculator works out; `quantity` is this unless it was typed over. */
  worked: number;
  quantity: number;
  price: number;
  total: number;
}

export interface Calc {
  sqft: number;
  sqyd: number;
  lines: CalcLine[];
  /** Tons and gallons. */
  materials: number;
  /** Everything else: milling, labor, trucks. */
  work: number;
  /** Before profit. */
  cost: number;
  crewDays: number;
  profitDays: number;
  profit: number;
  /** Added to bring a small job up to the minimum charge. */
  toMinimum: number;
  total: number;
  perSqft: number;
}

const round3 = (n: number) => Math.round(n * 1000) / 1000;
/** Bought whole: 146.67 tons is 147. Rounded to 0.001 first, so 150.0000001 stays 150. */
const wholeUp = (n: number) => Math.ceil(round3(n));
const nonNegative = (n: unknown) => (typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0);

function worked(item: CalcItem, value: number, sqft: number, extra: number, tons: number): number {
  const sqyd = sqft / 9;
  switch (item.basis) {
    case "depth":
      return wholeUp(((sqyd * value * (item.weight ?? DEFAULT_WEIGHT)) / LB_PER_TON) * extra);
    case "spread_lb":
      return wholeUp(((sqyd * value) / LB_PER_TON) * extra);
    case "spread_gal":
      return wholeUp(sqyd * value * extra);
    case "area_sqyd":
      return value > 0 ? round3(sqyd) : 0;
    case "area_sqft":
      return value > 0 ? round3(sqft) : 0;
    case "haul":
      return value > 0 ? round3(tons) : 0;
    default:
      return value;
  }
}

/** The whole bid: each item's amount, price and total, and the job's totals. */
export function calculate(setup: CalcSetup, input: CalcInput, overrides: Overrides = {}): Calc {
  const sqft = nonNegative(input.sqft);
  const extra = 1 + nonNegative(setup.waste) / 100;
  const lineFor = (item: CalcItem, tons: number): CalcLine => {
    const value = nonNegative(input.values[item.id]);
    const choice = item.choices?.find((c) => c.value === value);
    const price = choice?.price ?? item.price;
    const amount = worked(item, value, sqft, extra, tons);
    const typed = workedOut(item.basis) ? overrides[item.id] : undefined;
    const quantity = typed !== undefined && Number.isFinite(typed) && typed >= 0 ? typed : amount;
    return { item, value, unit: BASES[item.basis].unit, worked: amount, quantity, price, total: lineTotal(quantity, price) };
  };
  // Trucking hauls every ton of material on the job, as bought (typed-over amounts included).
  const tons = setup.items.reduce((t, item) => (BASES[item.basis].material && BASES[item.basis].unit === "ton" ? t + lineFor(item, 0).quantity : t), 0);
  const lines = setup.items.map((item) => lineFor(item, tons));
  const cents = (pick: (l: CalcLine) => boolean) => lines.filter(pick).reduce((t, l) => t + toCents(l.total), 0);
  const materials = cents((l) => BASES[l.item.basis].material);
  const work = cents((l) => !BASES[l.item.basis].material);
  const cost = materials + work;
  const crewDays = lines.reduce((t, l) => (l.item.basis === "days" && l.item.crew ? t + l.value : t), 0);
  const profitDays = input.profitDays ?? crewDays;
  const amount = nonNegative(input.profit.amount);
  const profit = input.profit.by === "day" ? toCents(lineTotal(profitDays, amount)) : input.profit.by === "percent" ? Math.round((cost * amount) / 100) : 0;
  // A small job comes up to the minimum; one with nothing priced yet stays at nothing.
  const minimum = toCents(nonNegative(input.minimum));
  const toMinimum = cost + profit > 0 && cost + profit < minimum ? minimum - cost - profit : 0;
  const total = (cost + profit + toMinimum) / 100;
  return {
    sqft,
    sqyd: round3(sqft / 9),
    lines,
    materials: materials / 100,
    work: work / 100,
    cost: cost / 100,
    crewDays,
    profitDays,
    profit: profit / 100,
    toMinimum: toMinimum / 100,
    total,
    perSqft: sqft ? total / sqft : 0,
  };
}

/** A fresh job: the first job type picked, trucking and mobilization on when they have prices, nothing else filled in. */
export const newInput = (setup: CalcSetup): CalcInput =>
  applyJob(
    setup,
    { job: null, sqft: 0, sides: null, values: Object.fromEntries(setup.items.filter(onByDefault).map((i) => [i.id, 1])), profit: { ...setup.profit }, profitDays: null, minimum: setup.minimum },
    setup.jobs[0]?.id ?? null,
  );

/** Picks a job type: the depths and rates worked from the area start over from its own. Days stay. */
export function applyJob(setup: CalcSetup, input: CalcInput, jobId: string | null): CalcInput {
  const job = setup.jobs.find((j) => j.id === jobId) ?? null;
  const values = { ...input.values };
  for (const item of setup.items) if (fromArea(item.basis)) values[item.id] = 0;
  return { ...input, job: job?.id ?? null, values: { ...values, ...(job?.values ?? {}) } };
}

/** The job type a calculator's choices make, to start the next job like this one. */
export function jobFrom(input: CalcInput, name: string, id: string): JobType {
  return { id, name, values: Object.fromEntries(Object.entries(input.values).filter(([, v]) => v > 0)) };
}

/**
 * The typed-over amounts still worth keeping after a change: one whose worked-out amount moved (a
 * new depth or area) goes back to what's worked out, so a stale number can't hide in the bid.
 */
export function keptOverrides(before: Calc, after: Calc, overrides: Overrides): Overrides {
  const amount = (calc: Calc, id: string) => calc.lines.find((l) => l.item.id === id)?.worked;
  return Object.fromEntries(Object.entries(overrides).filter(([id]) => amount(before, id) === amount(after, id)));
}

/** The section headings, in the order their first item comes. */
export const sectionsOf = (setup: CalcSetup) => [...new Set(setup.items.map((i) => i.section))];

/** What the quote line is called: the job type, or plain "Paving". */
export const jobName = (setup: CalcSetup, input: CalcInput) => setup.jobs.find((j) => j.id === input.job)?.name ?? "Paving";

/**
 * What the quote line is made of, kept on it (quote_line_items.parts) and on the job's line after:
 * each item the bid has any of, with its amount, what one costs and the kind of work it is. The
 * line itself has no price list item, so this is what weather rules, checklists and job costs go by.
 */
export const partsOf = (calc: Calc): LinePart[] =>
  calc.lines
    .filter((l) => l.quantity > 0)
    .map((l) => ({ id: l.item.id, name: l.item.name, unit: l.unit, quantity: l.quantity, unit_cost: l.price, ...(BASES[l.item.basis].material ? { material: true } : {}), ...(l.item.work ? { work: l.item.work } : {}) }));

// ---------------------------------------------------------------------------------------------
// Prices kept for every job
// ---------------------------------------------------------------------------------------------

/** `target` with the prices `source` has for the same items and choices, its profit and its minimum. */
export function withPrices(target: CalcSetup, source: CalcSetup): CalcSetup {
  const from = new Map(source.items.map((i) => [i.id, i]));
  return {
    ...target,
    profit: { ...source.profit },
    minimum: source.minimum,
    items: target.items.map((item) => {
      const other = from.get(item.id);
      if (!other) return item;
      const choices = item.choices?.map((c) => {
        const price = other.choices?.find((o) => o.value === c.value)?.price;
        return price === undefined ? c : { ...c, price };
      });
      return { ...item, price: other.price, ...(choices ? { choices } : {}) };
    }),
  };
}

/** Whether `source` prices anything `target` has differently. */
export const pricesDiffer = (target: CalcSetup, source: CalcSetup) => JSON.stringify(withPrices(target, source)) !== JSON.stringify(target);

// ---------------------------------------------------------------------------------------------
// Reading what's saved: settings and worksheets are JSON anyone in the office can write
// ---------------------------------------------------------------------------------------------

const amount = (v: unknown, fallback = 0) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? Math.min(v, 1e9) : fallback);
const text = (v: unknown, fallback: string, max = 80) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : fallback);
const record = (v: unknown): Record<string, unknown> => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {});
const numbers = (v: unknown) => Object.fromEntries(Object.entries(record(v)).filter(([, n]) => typeof n === "number" && Number.isFinite(n) && n >= 0)) as Record<string, number>;

function parseItem(raw: unknown, i: number): CalcItem | null {
  const r = record(raw);
  const basis = BASIS_IDS.includes(r.basis as Basis) ? (r.basis as Basis) : null;
  if (!basis) return null;
  const choices = Array.isArray(r.choices)
    ? r.choices.flatMap((c): Choice[] => {
        const o = record(c);
        const value = amount(o.value, -1);
        if (value <= 0) return [];
        return [{ label: text(o.label, String(value), 40), value, ...(o.price !== undefined && amount(o.price, -1) >= 0 ? { price: amount(o.price) } : {}) }];
      })
    : [];
  const id = text(r.id, `item-${i}`, 40);
  const standard = STANDARD_WORK.get(id);
  const work = isPavingWork(r.work) ? r.work : r.work === null ? null : standard?.basis === basis ? standard.work : undefined;
  return {
    id,
    name: text(r.name, "Item"),
    section: text(r.section, "Other", 40),
    basis,
    price: amount(r.price),
    ...(basis === "depth" ? { weight: amount(r.weight, DEFAULT_WEIGHT) || DEFAULT_WEIGHT } : {}),
    ...(choices.length ? { choices } : {}),
    ...(basis === "days" && r.crew === true ? { crew: true } : {}),
    ...(work !== undefined ? { work } : {}),
  };
}

const parseProfit = (raw: unknown, fallback: Profit): Profit => {
  const r = record(raw);
  return ["day", "percent", "none"].includes(r.by as string) ? { by: r.by as ProfitBy, amount: amount(r.amount) } : { ...fallback };
};

/** A setup as saved, with anything that isn't one dropped; the standard setup when there's none. */
export function parseSetup(raw: unknown): CalcSetup {
  const r = record(raw);
  if (!Array.isArray(r.items)) return structuredClone(DEFAULT_SETUP);
  const seen = new Set<string>();
  const items = r.items.map(parseItem).filter((i): i is CalcItem => i !== null && !seen.has(i.id) && Boolean(seen.add(i.id)));
  const jobs = Array.isArray(r.jobs)
    ? r.jobs.flatMap((j, i): JobType[] => {
        const o = record(j);
        return [{ id: text(o.id, `job-${i}`, 40), name: text(o.name, "Job"), values: numbers(o.values) }];
      })
    : [];
  return { items, jobs, profit: parseProfit(r.profit, DEFAULT_SETUP.profit), waste: Math.min(amount(r.waste), 100), minimum: amount(r.minimum) };
}

/** The business's setup, from companies.settings. */
export const setupFrom = (settings: unknown) => parseSetup(record(settings).paving_calculator);

/** A worksheet as saved, or null when it isn't one. */
export function parseWorksheet(raw: unknown): WorksheetData | null {
  const r = record(raw);
  if (r.v !== 1) return null;
  const setup = parseSetup(r.setup);
  const i = record(r.input);
  const sides = Array.isArray(i.sides) ? i.sides.map((s) => ({ length: amount(record(s).length), width: amount(record(s).width) })) : null;
  return {
    v: 1,
    setup,
    input: {
      job: typeof i.job === "string" ? i.job : null,
      sqft: amount(i.sqft),
      sides: sides?.length ? sides : null,
      values: numbers(i.values),
      profit: parseProfit(i.profit, setup.profit),
      profitDays: i.profitDays === null || i.profitDays === undefined ? null : amount(i.profitDays),
      minimum: amount(i.minimum),
    },
    overrides: numbers(r.overrides),
  };
}

// ---------------------------------------------------------------------------------------------
// What the client reads
// ---------------------------------------------------------------------------------------------

const n = (value: number) => value.toLocaleString("en-US", { maximumFractionDigits: 2 });
const UNIT_WORDS: Record<string, [string, string]> = { ton: ["ton", "tons"], gal: ["gal", "gal"], ft: ["ft", "ft"], ea: ["", ""] };

/**
 * What the job is, in words the client can read on the proposal: the area and the work, with the
 * amounts of material but none of the prices, days or profit.
 */
export function scopeText(calc: Calc): string {
  const parts = calc.lines.flatMap((l) => {
    // Days, trucking and mobilization are how the job gets done, not what the client gets.
    if (l.quantity <= 0 || l.item.basis === "days" || l.item.basis === "haul" || l.item.basis === "flat") return [];
    const choice = l.item.choices?.find((c) => c.value === l.value);
    if (l.item.basis === "area_sqyd" || l.item.basis === "area_sqft") return [choice ? `${l.item.name} (${choice.label})` : l.item.name];
    const [one, many] = UNIT_WORDS[l.unit] ?? [l.unit, l.unit];
    const depth = l.item.basis === "depth" && l.value > 0 && l.quantity === l.worked ? `, ${n(l.value)}" deep` : "";
    return [`${l.item.name}${depth}: ${n(l.quantity)}${one ? ` ${l.quantity === 1 ? one : many}` : ""}`];
  });
  return [`${n(calc.sqft)} sq ft (${n(Math.round(calc.sqyd))} sq yd)`, ...parts].join(". ") + ".";
}

/**
 * The labor in the bid's cost: its crew days. The quote line says so (unit_labor_cost), and job costs
 * leave it out once the job has clocked time or crew pay of its own, so labor isn't counted twice.
 */
export const laborOf = (calc: Calc) => Math.min(calc.cost, calc.lines.reduce((t, l) => (l.item.basis === "days" && l.item.crew ? t + toCents(l.total) : t), 0) / 100);

/**
 * The quote line for the whole job: priced at the bid, costed at the bid before profit, with the
 * labor in that cost and what the line is made of.
 */
export const quoteLine = (setup: CalcSetup, input: CalcInput, calc: Calc) => ({
  name: jobName(setup, input),
  description: scopeText(calc),
  quantity: 1,
  unit: "job",
  unit_price: calc.total,
  unit_cost: calc.cost,
  unit_labor_cost: laborOf(calc),
  parts: partsOf(calc),
});
