/**
 * Changing prices across repeating jobs (supabase/migrations/20261113000950_price_changes.sql). The
 * database works out every new price (price_change_preview) and makes the change only for lines that
 * are exactly what it previewed (apply_price_change); these build what's asked, split a preview into
 * the groups of jobs sent to it, and say it on screen, in a CSV and to an AI assistant.
 */

export type PriceChangeKind = "percent" | "amount";
export type PriceRounding = "cent" | "half" | "dollar";

/** Which active repeating jobs: all of them, or narrowed. `job_ids`: only these. */
export interface PriceChangePick {
  /** Jobs with a line for this price list item. */
  service_id?: string | null;
  client_tag?: string | null;
  crew_id?: string | null;
  job_ids?: string[] | null;
}

/** What the database is asked (p_change). `value` above 0 raises prices, below lowers them. */
export interface PriceChange {
  kind: PriceChangeKind;
  value: number;
  round: PriceRounding;
  /** Only this price list item's lines; every priced line without it. */
  line_service_id?: string | null;
  jobs?: PriceChangePick;
}

export interface PriceChangeLine {
  line_id: string;
  name: string;
  quantity: number;
  unit: string;
  old_price: number;
  new_price: number;
}

export interface PriceChangeJob {
  job_id: string;
  number: number | null;
  title: string;
  client_id: string;
  client: string;
  pricing: "per_visit" | "fixed";
  schedule: string | null;
  /** The job's price for a visit, or (a fixed price) for each invoice, before and after. */
  old_price: number;
  new_price: number;
  autopay: boolean;
  /** On autopay, and the new price with tax is over the company's autopay limit. */
  over_limit: boolean;
  was_over_limit: boolean;
  lines: PriceChangeLine[];
}

export interface PriceChangePreview {
  summary: string;
  jobs: PriceChangeJob[];
  totals: { jobs: number; lines: number; old_price: number; new_price: number };
  /** Null when autopay is off, or the person doesn't have the invoices area. */
  autopay: { limit: number | null; jobs: number; over_limit: number } | null;
}

export const ROUNDING_CHOICES: ReadonlyArray<{ value: PriceRounding; label: string }> = [
  { value: "cent", label: "To the cent" },
  { value: "half", label: "To 50 cents" },
  { value: "dollar", label: "To the dollar" },
];

/** What the form holds: the amount as typed, and which way. */
export interface PriceChangeForm {
  direction: "up" | "down";
  kind: PriceChangeKind;
  amount: string;
  round: PriceRounding;
  lineServiceId?: string | null;
  pick?: PriceChangePick;
}

/**
 * The change the form asks for, or what's wrong with it, in the database's own words
 * (private.price_change_checked): a percentage up to 500 or down by less than 100, or an amount.
 */
export function priceChangeOf(form: PriceChangeForm): PriceChange | string {
  const amount = Number(form.amount);
  if (form.amount.trim() === "" || !Number.isFinite(amount) || amount <= 0) return "Enter how much to change prices by.";
  if (form.kind === "percent" && (form.direction === "up" ? amount > 500 : amount >= 100)) return "Enter a percentage up to 500, or down by less than 100.";
  if (form.kind === "amount" && amount > 100_000) return "That amount is too large.";
  const pick = form.pick ?? {};
  const jobs: PriceChangePick = {
    ...(pick.service_id && { service_id: pick.service_id }),
    ...(pick.client_tag?.trim() && { client_tag: pick.client_tag.trim() }),
    ...(pick.crew_id && { crew_id: pick.crew_id }),
    ...(pick.job_ids && { job_ids: pick.job_ids }),
  };
  return {
    kind: form.kind,
    value: form.direction === "down" ? -amount : amount,
    round: form.round,
    ...(form.lineServiceId && { line_service_id: form.lineServiceId }),
    ...(Object.keys(jobs).length > 0 && { jobs }),
  };
}

/** How many jobs go to the database in one call: each call is one transaction, so no job is half changed. */
export const PRICE_CHANGE_JOBS = 100;

/**
 * The preview's lines as apply_price_change takes them, a group of whole jobs at a time, for the
 * jobs picked (all of them unless `only` says which).
 */
export function priceChangeGroups(jobs: readonly PriceChangeJob[], only?: ReadonlySet<string> | null, size = PRICE_CHANGE_JOBS): Array<{ jobs: number; lines: Array<{ line_id: string; old_price: number; new_price: number }> }> {
  const picked = only ? jobs.filter((j) => only.has(j.job_id)) : jobs;
  const groups: Array<{ jobs: number; lines: Array<{ line_id: string; old_price: number; new_price: number }> }> = [];
  for (let i = 0; i < picked.length; i += size) {
    const group = picked.slice(i, i + size);
    groups.push({ jobs: group.length, lines: group.flatMap((j) => j.lines.map((l) => ({ line_id: l.line_id, old_price: l.old_price, new_price: l.new_price }))) });
  }
  return groups;
}

const cents = (n: number) => Math.round(n * 100) / 100;

/** What the jobs picked come to, before and after: how many jobs and lines, and the sum of the jobs' prices. */
export function priceChangeTotals(jobs: readonly PriceChangeJob[], only?: ReadonlySet<string> | null) {
  const picked = only ? jobs.filter((j) => only.has(j.job_id)) : jobs;
  return {
    jobs: picked.length,
    lines: picked.reduce((n, j) => n + j.lines.length, 0),
    old_price: cents(picked.reduce((s, j) => s + Number(j.old_price), 0)),
    new_price: cents(picked.reduce((s, j) => s + Number(j.new_price), 0)),
    autopay: picked.filter((j) => j.autopay).length,
    // Newly over the limit: a job already over it waits for the office's OK today as well.
    over_limit: picked.filter((j) => j.over_limit && !j.was_over_limit).length,
  };
}

/** "a visit" or "a month": what a job's price is for. */
export const priceIsFor = (job: Pick<PriceChangeJob, "pricing" | "schedule">) => (job.pricing === "fixed" ? (job.schedule === "monthly" ? "a month" : "an invoice") : "a visit");

/**
 * What a price change means for clients on autopay, by the rules autopay already has: nobody is
 * asked to agree again (they're asked only when the terms' words change), their card is charged the
 * new price from the next invoice, and a charge over the company's limit waits for the office's OK
 * (a bank account is never charged over it: that invoice goes to the client to pay).
 * Null when none of the jobs is on autopay.
 */
export function autopayNote(totals: { autopay: number; over_limit: number }, limit: number | null, money: (n: number) => string): string | null {
  if (!totals.autopay) return null;
  const jobs = `${totals.autopay} of these ${totals.autopay === 1 ? "jobs is" : "jobs are"} on autopay`;
  const charged = "Their clients aren't asked to agree again: the saved card is charged the new price from the next invoice.";
  if (!totals.over_limit || limit == null) return `${jobs}. ${charged}`;
  return `${jobs}. ${charged} ${totals.over_limit} would go over your ${money(limit)} autopay limit, so ${totals.over_limit === 1 ? "that charge waits" : "those charges wait"} for your OK each time. A client who pays from a bank account is sent the invoice to pay instead.`;
}

/** The preview as rows for a CSV: one for each line changed, with its job and the job's price before and after. */
export function priceChangeRows(jobs: readonly PriceChangeJob[], only?: ReadonlySet<string> | null): Array<Record<string, string | number>> {
  const picked = only ? jobs.filter((j) => only.has(j.job_id)) : jobs;
  return picked.flatMap((j) =>
    j.lines.map((l) => ({
      job: j.number ?? "",
      title: j.title,
      client: j.client,
      line: l.name,
      quantity: Number(l.quantity),
      old_price: Number(l.old_price).toFixed(2),
      new_price: Number(l.new_price).toFixed(2),
      job_price_for: priceIsFor(j),
      job_old_price: Number(j.old_price).toFixed(2),
      job_new_price: Number(j.new_price).toFixed(2),
      autopay: j.autopay ? (j.over_limit ? "Yes, over the limit" : "Yes") : "",
    })),
  );
}

export const PRICE_CHANGE_COLUMNS: ReadonlyArray<{ key: string; label: string }> = [
  { key: "job", label: "Job #" },
  { key: "title", label: "Job" },
  { key: "client", label: "Client" },
  { key: "line", label: "Line" },
  { key: "quantity", label: "Quantity" },
  { key: "old_price", label: "Old price" },
  { key: "new_price", label: "New price" },
  { key: "job_price_for", label: "Job price is for" },
  { key: "job_old_price", label: "Job's old price" },
  { key: "job_new_price", label: "Job's new price" },
  { key: "autopay", label: "Autopay" },
];
