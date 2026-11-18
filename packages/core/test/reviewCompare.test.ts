import { describe, expect, it } from "vitest";
import * as shared from "../src/reviewCompare";
import { MAX_COMPETITORS, PLACE_ID, ranked, standing, standingWords, type ComparedPlace } from "../src/reviewCompare";

const place = (id: string, rating: number | null, total: number | null, own = false): ComparedPlace => ({ id, name: id, is_own: own, rating, ratings_total: total });

describe("what may be saved about a place", () => {
  it("is its Google ID, which is letters, digits, hyphens and underscores", () => {
    expect(PLACE_ID.test("ChIJj61dQgK6j4AR4GeTYWZsKWw")).toBe(true);
    expect(PLACE_ID.test("GhIJQWDl0CIeQUARxks3icF8U8A")).toBe(true);
    expect(PLACE_ID.test("EicxMyBNYXJrZXQgU3QsIFdpbG1pbmd0b24sIE5DIDI4NDAxLCBVU0E")).toBe(true);
    // Not a name, an address, a link or a rating.
    for (const not of ["Rival Gutters", "1 Elm St, Springfield, IL", "https://maps.google.com/?cid=1", "4.7", "", "x".repeat(301)]) expect(PLACE_ID.test(not), not).toBe(false);
    expect(MAX_COMPETITORS).toBe(5);
  });

  it("has no week-on-week change left to work out, which needed last week's count kept", () => {
    for (const gone of ["autoDue", "nextHandCheck", "countChange", "changesSince", "changeWords", "AUTO_DAYS", "HAND_HOURS"]) expect(shared).not.toHaveProperty(gone);
  });
});

describe("where the business stands", () => {
  const places = [place("us", 4.6, 80, true), place("big", 4.8, 300), place("mid", 4.6, 120), place("low", 3.9, 40), place("new", null, null)];

  it("ranks by rating, then by number of reviews, with places that have no rating last", () => {
    expect(ranked(places).map((p) => p.id)).toEqual(["big", "mid", "us", "low", "new"]);
  });

  it("compares the business with the competitors' averages", () => {
    // Competitors with a rating: 4.8, 4.6, 3.9 → 4.43; reviews 300, 120, 40 → 153.3.
    expect(standing(places)).toEqual({ rank: 3, of: 4, ratingVsAverage: 0.2, reviewsVsAverage: -73 });
    expect(standingWords({ rank: 3, of: 4 })).toBe("3rd of 4 by rating");
    expect(standingWords({ rank: 1, of: 6 })).toBe("Highest rated of 6");
    expect(standingWords({ rank: 2, of: 6 })).toBe("2nd of 6 by rating");
    expect(standingWords({ rank: 11, of: 12 })).toBe("11th of 12 by rating");
  });

  it("says nothing without the business's own place or a competitor read", () => {
    expect(standing(places.filter((p) => !p.is_own))).toBeNull();
    expect(standing([place("us", 4.6, 80, true), place("new", null, null)])).toBeNull();
    expect(standing([place("us", 4.6, 80, true), place("b", 4.0, 10)])).toMatchObject({ rank: 1, of: 2 });
  });
});
