/**
 * Whether break time is paid, as the company sets it (settings.clock.breaks). Platform-free, so
 * Timesheets, Reports and the API count paid hours the same way.
 *
 * Under federal rules (29 CFR 785.18 and 785.19), short rest breaks of about 20 minutes or less are
 * paid work time, and a real meal break, with the person fully off duty, needn't be: "Ordinarily 30
 * minutes or more is long enough for a bona fide meal period" (785.19(a)). The default pays a
 * break of 20 minutes or less and not a longer one, so a quick water break in the heat is paid and
 * a half-hour lunch isn't. A break of 21 to 29 minutes is unpaid under it too, which the federal
 * rules don't promise is right: the setting's hint says so, rather than claiming to follow them.
 */
export type BreakPay = "short_paid" | "paid" | "unpaid";

export const BREAK_PAY_LABELS: Record<BreakPay, string> = {
  short_paid: "Paid if 20 minutes or less",
  paid: "Always paid",
  unpaid: "Never paid",
};

/** The longest break that's still paid under "Paid if 20 minutes or less". */
export const SHORT_BREAK_MINUTES = 20;

/** One line under the setting for each choice: what it does, and what the federal rules say about it. */
export const BREAK_PAY_HINTS: Record<BreakPay, string> = {
  short_paid:
    "Breaks of 20 minutes or less count as paid time, and longer ones don't, so a 25-minute break is unpaid here. Under federal rules a rest break of about 20 minutes or less is paid, and a meal break that needn't be paid is ordinarily 30 minutes or more with the person fully off duty. If your crew takes breaks of 21 to 29 minutes, choose Always paid or check your state's rules.",
  paid: "Every break counts as paid time, lunch included.",
  unpaid: "No break counts as paid time. Federal rules say rest breaks of 20 minutes or less must be paid, so check before choosing this.",
};

/** The company's rule, from its settings. */
export function breakPay(settings: unknown): BreakPay {
  const value = (settings as { clock?: { breaks?: unknown } } | null | undefined)?.clock?.breaks;
  return value === "paid" || value === "unpaid" ? value : "short_paid";
}

/**
 * Whether a time entry is break time the company doesn't pay for, so it's left out of paid hours.
 * A break still running is judged on its length so far.
 */
export function isUnpaidBreak(entry: { category: string; started_at: string; ended_at: string | null }, pay: BreakPay, now = Date.now()): boolean {
  if (entry.category !== "break" || pay === "paid") return false;
  if (pay === "unpaid") return true;
  const minutes = ((entry.ended_at ? Date.parse(entry.ended_at) : now) - Date.parse(entry.started_at)) / 60_000;
  return minutes > SHORT_BREAK_MINUTES;
}
