/**
 * Settings → Company's next numbers: the number the next request, quote, job and invoice gets, read
 * and set through the database's own functions (public.next_numbers, public.set_next_number;
 * supabase/migrations/20261113000130_next_numbers.sql), which check the role and the numbers in use.
 */

/** The kinds, in the order work goes through them, as the database names them. */
export const NUMBER_KINDS = [
  { kind: "request", label: "Next request number" },
  { kind: "quote", label: "Next quote number" },
  { kind: "job", label: "Next job number" },
  { kind: "invoice", label: "Next invoice number" },
] as const;
export type NumberKind = (typeof NUMBER_KINDS)[number]["kind"];

/** A row of public.next_numbers: the next number of a kind, and the highest one in use (0 for none). */
export interface NextNumber {
  kind: string;
  next_number: number;
  highest_used: number;
}

/** The most a number can be set to (set_next_number). */
export const HIGHEST_NUMBER = 999_999_999;

/**
 * What's wrong with a next number as typed, or null: in the words set_next_number refuses it with,
 * so the form says so before anything is saved. The database checks again when it saves.
 */
export function nextNumberProblem(kind: NumberKind, typed: string, highestUsed: number): string | null {
  const text = typed.trim();
  const n = Number(text);
  if (!/^\d+$/.test(text) || n < 1 || n > HIGHEST_NUMBER) return "Enter a whole number from 1 to 999,999,999.";
  if (n <= highestUsed) {
    return `${kind[0]!.toUpperCase()}${kind.slice(1)} #${highestUsed} is already used, so the next number has to be ${highestUsed + 1} or higher. Two ${kind}s can't share a number.`;
  }
  return null;
}

/** The kinds whose typed number differs from the one saved, with the number to save. */
export function changedNumbers(saved: readonly NextNumber[], typed: Readonly<Record<string, string>>): Array<{ kind: NumberKind; next: number }> {
  return NUMBER_KINDS.flatMap(({ kind }) => {
    const text = typed[kind]?.trim();
    const now = saved.find((s) => s.kind === kind)?.next_number;
    return text !== undefined && text !== "" && Number(text) !== Number(now) ? [{ kind, next: Number(text) }] : [];
  });
}
