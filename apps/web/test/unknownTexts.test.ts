/** Texts from unknown numbers, as Messages lists them (features/messages/unknownTexts.ts). */
import { describe, expect, it } from "vitest";
import { byNumber, matchingNumbers, numberWords } from "../src/features/messages/unknownTexts";

const text = (id: string, from_phone: string, body: string, created_at: string) => ({ id, from_phone, phone_key: from_phone.replace(/\D/g, "").slice(-10), body, created_at });
// As the database sends them: newest first.
const texts = [
  text("t4", "+15125550163", "Still there?", "2026-11-13T15:30:00Z"),
  text("t3", "+15125550177", "It's Bo, new number", "2026-11-13T15:00:00Z"),
  text("t2", "+15125550163", "This is Ada's husband", "2026-11-13T14:00:00Z"),
  text("t1", "+15125550163", "Do you plow driveways?", "2026-11-13T13:00:00Z"),
];

describe("unknown numbers in Messages", () => {
  it("are one row a number, with its newest text and how many it sent", () => {
    expect(byNumber(texts).map((n) => [n.from_phone, n.body, n.count])).toEqual([
      ["+15125550163", "Still there?", 3],
      ["+15125550177", "It's Bo, new number", 1],
    ]);
    expect(byNumber([])).toEqual([]);
  });

  it("read as people write numbers", () => {
    expect(numberWords("+15125550163")).toBe("(512) 555-0163");
    expect(numberWords("+442079460958")).toBe("+442079460958");
    expect(numberWords("12345")).toBe("12345");
  });

  it("are found by the number however it's typed, or by what a text said", () => {
    const numbers = byNumber(texts);
    expect(matchingNumbers(numbers, "")).toHaveLength(2);
    expect(matchingNumbers(numbers, "(512) 555-0177").map((n) => n.from_phone)).toEqual(["+15125550177"]);
    expect(matchingNumbers(numbers, "0163").map((n) => n.from_phone)).toEqual(["+15125550163"]);
    expect(matchingNumbers(numbers, "new NUMBER").map((n) => n.from_phone)).toEqual(["+15125550177"]);
    expect(matchingNumbers(numbers, "gutters")).toEqual([]);
  });
});
