/**
 * What a drafted quote tells the office (quotes/DraftedCallout.tsx): who drafted it, the lines whose
 * quantity to check (only those still on it), and why Claude didn't draft it when it was meant to.
 */
import { describe, expect, it } from "vitest";
import { cutListWords, descriptionWaiting, draftedWords, readDrafted, readyDraft } from "@/features/quotes/DraftedCallout";

describe("a drafted quote", () => {
  it("reads quotes.drafted, and anything else as not drafted", () => {
    expect(readDrafted(null)).toBeNull();
    expect(readDrafted({ by: "someone" })).toBeNull();
    expect(readDrafted({ by: "claude", request_number: 12, check: ["l1", 3], notes: "Size: Large" })).toEqual({ by: "claude", request_number: 12, check: ["l1"], lines: null, notes: "Size: Large", note: null });
  });

  it("points a request at the draft made by itself as it came in, until that quote is sent", () => {
    const auto = { id: "q1", number: 40, status: "draft", drafted: { by: "claude", auto: true } };
    expect(readyDraft([{ id: "q0", number: 39, status: "draft", drafted: null }, auto])).toEqual({ quote: auto, by: "claude" });
    expect(readyDraft([{ ...auto, drafted: { by: "price_list", auto: true } }])?.by).toBe("price_list");
    // Sent, it's a quote like any other; one a person drafted marked the request Quoted already.
    expect(readyDraft([{ ...auto, status: "sent" }])).toBeNull();
    expect(readyDraft([{ id: "q2", number: 41, status: "draft", drafted: { by: "claude" } }])).toBeNull();
    expect(readyDraft([])).toBeNull();
    expect(readDrafted({ by: "claude", auto: true })?.auto).toBe(true);
    expect(readDrafted({ by: "claude", auto: "yes" })).not.toHaveProperty("auto");
  });

  it("keeps Claude's description for a draft made by itself until it's used as the message", () => {
    const d = readDrafted({ by: "claude", auto: true, description: " Weekly mowing, front and back. " })!;
    expect(d.description).toBe("Weekly mowing, front and back.");
    expect(descriptionWaiting(d, null)).toBe(true);
    expect(descriptionWaiting(d, "Thanks for asking us.")).toBe(true);
    expect(descriptionWaiting(d, "Weekly mowing, front and back.")).toBe(false);
    // One a person drafted has it as the message already, so nothing waits.
    expect(descriptionWaiting(readDrafted({ by: "claude" })!, "Weekly mowing.")).toBe(false);
  });

  it("says when the price list was too long to go by whole", () => {
    expect(cutListWords(readDrafted({ by: "claude", price_list: { shown: 500, of: 1742 } })!)).toBe("Your price list has 1,742 items, and the AI was shown the first 500. Check that nothing further down is missing.");
    expect(draftedWords(readDrafted({ by: "price_list", request_number: 3, price_list: { shown: 500, of: 742 } })!, []).at(-1)).toBe("Your price list has 742 items, and this draft went by the first 500. Check that nothing further down is missing.");
    expect(cutListWords(readDrafted({ by: "claude", price_list: { shown: 500, of: 500 } })!)).toBeNull();
    expect(cutListWords(readDrafted({ by: "claude" })!)).toBeNull();
  });

  it("says who drafted it and what to check", () => {
    expect(draftedWords({ by: "claude", request_number: 12 }, ["Mowing", "Edging"])).toEqual([
      // Said to whoever opens the draft, who may not be the one who turned drafting on: it's AI's, and to check it.
      "Written by AI: this was drafted from request #12 and your price list. It can be wrong, so check every line, quantity and price before you send it.",
      "Check the quantity on Mowing, Edging: the request didn't say, so it's 1.",
    ]);
    expect(draftedWords({ by: "price_list", note: "The AI couldn't draft this one (busy), so it was drafted from your price list." }, [])).toEqual([
      "Drafted from the request and your price list. Look it over before you send it.",
      "The AI couldn't draft this one (busy), so it was drafted from your price list.",
    ]);
    // A draft that came with no lines isn't called drafted.
    expect(draftedWords({ by: "price_list", request_number: 7, lines: 0, note: "Nothing on your price list matched what they asked for. Add the lines yourself." }, [])).toEqual([
      "Started from request #7.",
      "Nothing on your price list matched what they asked for. Add the lines yourself.",
    ]);
  });
});
