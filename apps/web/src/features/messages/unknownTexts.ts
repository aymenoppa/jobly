/** Texts from unknown numbers (public.unknown_texts), as Messages lists them: one row for each number. */
import { phoneDisplay, phoneE164 } from "@jobly/core/phone";

export interface UnknownText {
  id: string;
  from_phone: string;
  phone_key: string;
  body: string;
  created_at: string;
}

/** One unknown number: its newest text, and how many it sent. */
export interface UnknownNumber extends UnknownText {
  count: number;
}

/** The number as people read it: "(512) 555-0163" for a US or Canadian one. */
export const numberWords = (phone: string) => {
  const e164 = phoneE164(phone);
  return e164 ? phoneDisplay(e164) : phone;
};

/** From texts newest first: one row for each number, with its newest text. */
export function byNumber(texts: readonly UnknownText[]): UnknownNumber[] {
  const seen = new Map<string, UnknownNumber>();
  for (const t of texts) {
    const existing = seen.get(t.phone_key);
    if (existing) existing.count++;
    else seen.set(t.phone_key, { ...t, count: 1 });
  }
  return [...seen.values()];
}

/** The numbers a search finds: by the number, however it's typed, or by what a text said. */
export function matchingNumbers(numbers: readonly UnknownNumber[], term: string): UnknownNumber[] {
  const words = term.trim().toLowerCase();
  if (!words) return [...numbers];
  const digits = words.replace(/\D/g, "");
  return numbers.filter((n) => n.body.toLowerCase().includes(words) || (digits.length >= 3 && n.from_phone.replace(/\D/g, "").includes(digits)));
}
