/**
 * The Google reviews a quote shows (src/reviews.ts quoteReviews): the office's picks in order, else
 * the newest with 5 stars and words; never one taken off Google; three at most; each as it is on
 * Google, the reviewer's name and their words unchanged. Where a page hasn't room for a long one
 * it's cut only beside a link to read it on Google, and left out without one. And how fresh a copy
 * has to be to be shown at all.
 */
import { describe, expect, it } from "vitest";
import { cutReview, fitReviews, HUB_REVIEW_CHARS, isFresh, PDF_REVIEW_CHARS, profileLink, quoteReviews, REVIEW_FRESH_DAYS, reviewerDisplayName, reviewsFreshSince, type QuoteReviewRow } from "../src/reviews";

const review = (over: Partial<QuoteReviewRow>): QuoteReviewRow => ({
  reviewer_name: "Dana Whitfield", reviewer_anonymous: false, rating: 5, comment: "Great job.", posted_at: "2026-10-01T15:00:00Z", quote_pick: null, deleted_at: null, ...over,
});

describe("reviews on quotes", () => {
  it("shows the newest three with 5 stars and words when none are picked", () => {
    const rows = [
      review({ reviewer_name: "Ann Old", posted_at: "2026-01-01T00:00:00Z" }),
      review({ reviewer_name: "Bo Four", rating: 4, posted_at: "2026-11-01T00:00:00Z" }),
      review({ reviewer_name: "Cy Quiet", comment: "  ", posted_at: "2026-11-02T00:00:00Z" }),
      review({ reviewer_name: "Di New", posted_at: "2026-11-03T00:00:00Z" }),
      review({ reviewer_name: "Ed Gone", posted_at: "2026-11-04T00:00:00Z", deleted_at: "2026-11-05T00:00:00Z" }),
      review({ reviewer_name: "Fay Mid", posted_at: "2026-06-01T00:00:00Z" }),
      review({ reviewer_name: "Gus Older", posted_at: "2025-06-01T00:00:00Z" }),
    ];
    expect(quoteReviews(rows).map((r) => r.name)).toEqual(["Di New", "Fay Mid", "Ann Old"]);
  });

  it("shows the office's picks in their order, whatever their stars", () => {
    const rows = [
      review({ reviewer_name: "Ann Five", posted_at: "2026-11-03T00:00:00Z" }),
      review({ reviewer_name: "Bo Picked", rating: 4, comment: "Good, a bit late.", quote_pick: 2 }),
      review({ reviewer_name: "Cy First", quote_pick: 1 }),
    ];
    expect(quoteReviews(rows)).toEqual([
      { name: "Cy First", rating: 5, date: "2026-10-01", text: "Great job." },
      { name: "Bo Picked", rating: 4, date: "2026-10-01", text: "Good, a bit late." },
    ]);
  });

  it("falls back to the newest when every pick was taken off Google, and shows nothing with nothing to show", () => {
    expect(quoteReviews([review({ quote_pick: 1, deleted_at: "2026-11-01T00:00:00Z" }), review({ reviewer_name: "Al Live" })]).map((r) => r.name)).toEqual(["Al Live"]);
    expect(quoteReviews([review({ rating: 3 }), review({ comment: null })])).toEqual([]);
    expect(quoteReviews([])).toEqual([]);
  });

  it("names the reviewer as Google does, and keeps their words whole", () => {
    expect(reviewerDisplayName({ reviewer_name: "Dana Whitfield-Jones", reviewer_anonymous: false })).toBe("Dana Whitfield-Jones");
    expect(reviewerDisplayName({ reviewer_name: "  maria de la cruz ", reviewer_anonymous: false })).toBe("maria de la cruz");
    expect(reviewerDisplayName({ reviewer_name: "Dana Whitfield", reviewer_anonymous: true })).toBe("A Google user");
    expect(reviewerDisplayName({ reviewer_name: null, reviewer_anonymous: false })).toBe("A Google user");
    const long = `Fast,\n\nfriendly   and fair. ${"Really great work on the deck. ".repeat(40)}`;
    const [shown] = quoteReviews([review({ reviewer_name: "José Ñúñez", comment: `  ${long}\n` })]);
    expect(shown).toEqual({ name: "José Ñúñez", rating: 5, date: "2026-10-01", text: long.trim() });
  });

  it("cuts a review too long for the page at a word, and says it was cut", () => {
    expect(cutReview("Fast,\n\nfriendly   and fair.", 60)).toEqual({ text: "Fast,\n\nfriendly   and fair.", cut: false });
    const long = "Really great work on the deck. ".repeat(12);
    const cut = cutReview(long, 60);
    expect(cut).toEqual({ text: "Really great work on the deck. Really great work on the…", cut: true });
    expect(cut.text.length).toBeLessThanOrEqual(60);
    expect(cutReview("x".repeat(80), 60)).toEqual({ text: `${"x".repeat(59)}…`, cut: true });
    expect(cutReview(null, 60)).toEqual({ text: "", cut: false });
    expect(cutReview("x".repeat(PDF_REVIEW_CHARS), PDF_REVIEW_CHARS).cut).toBe(false);
    expect(PDF_REVIEW_CHARS).toBeLessThan(HUB_REVIEW_CHARS);
  });

  it("shows a cut review only with a link to read it on Google", () => {
    const reviews = [{ name: "Short", text: "Great job." }, { name: "Long", text: "Great work on the deck. ".repeat(20) }];
    const linked = fitReviews(reviews, 60, "https://maps.google.com/?cid=9");
    expect(linked.map((r) => [r.name, r.cut])).toEqual([["Short", false], ["Long", true]]);
    expect(linked[1]!.text.endsWith("…")).toBe(true);
    // With nowhere to read the rest, the long one is left out rather than shown shortened.
    expect(fitReviews(reviews, 60, null).map((r) => r.name)).toEqual(["Short"]);
    expect(fitReviews(reviews, 60, undefined).map((r) => r.name)).toEqual(["Short"]);
    // What an older server already shortened fits, and shows as it came.
    expect(fitReviews([{ text: `${"x".repeat(279)}…` }], PDF_REVIEW_CHARS, null)).toEqual([{ text: `${"x".repeat(279)}…`, cut: false }]);
  });

  it("links to the business's profile on Google Maps", () => {
    expect(profileLink({ maps_uri: "https://maps.google.com/?cid=9", place_id: "place-9" })).toBe("https://maps.google.com/?cid=9");
    expect(profileLink({ maps_uri: null, place_id: "ChIJ place/9", title: "Oakridge Lawn & Care" })).toBe("https://www.google.com/maps/search/?api=1&query=Oakridge%20Lawn%20%26%20Care&query_place_id=ChIJ%20place%2F9");
    expect(profileLink({ maps_uri: "javascript:alert(1)", place_id: null })).toBeNull();
    expect(profileLink({})).toBeNull();
  });
});

describe("how long a copy of a review is shown", () => {
  it("is a day short of 30, so a tidy that runs once a day never leaves one past 30", () => {
    expect(REVIEW_FRESH_DAYS).toBe(29);
    const now = Date.UTC(2026, 10, 14, 12);
    expect(reviewsFreshSince(now)).toBe("2026-10-16T12:00:00.000Z");
    expect(reviewsFreshSince(new Date(now))).toBe("2026-10-16T12:00:00.000Z");
    expect(isFresh("2026-10-16T12:00:01Z", now)).toBe(true);
    expect(isFresh("2026-10-16T12:00:00Z", now)).toBe(false);
    expect(isFresh(null, now)).toBe(false);
    expect(isFresh(undefined, now)).toBe(false);
  });
});
