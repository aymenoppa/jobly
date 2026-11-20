/**
 * Google reviews on a quote in the Client Hub (features/hub/HubReviews.tsx): shown as Google's, with
 * the reviewer's name and words as the server sent them, a long review cut only beside a link to
 * read it on Google, and a link to the business's profile there.
 */
import { HUB_REVIEW_CHARS } from "@jobly/core/reviews";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { HubReviews as Reviews } from "../src/features/hub/document";
import { HubReviews } from "../src/features/hub/HubReviews";

const LINK = "https://maps.google.com/?cid=9";
const one = (over: Partial<Reviews["reviews"][number]> = {}) => ({ name: "Dana Whitfield-Jones", rating: 5, date: "2026-10-01", text: "Fast,\nfriendly and fair.", ...over });
const html = (reviews: Reviews | null) => renderToStaticMarkup(createElement(HubReviews, { reviews }));
const text = (markup: string) => markup.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ");

describe("Google reviews on a quote", () => {
  it("are marked as Google's, with the reviewer's name and words as they are there", () => {
    const page = html({ rating: 4.8, count: 120, reviews: [one()], link: LINK, pdf: false });
    expect(page).toContain("What clients say on Google");
    expect(text(page)).toContain("4.8 on Google · 120 reviews");
    // The whole name and the words with their line break, not a first name and initial or folded text.
    expect(page).toContain("Dana Whitfield-Jones");
    expect(page).toContain("Fast,\nfriendly and fair.");
    expect(text(page)).toContain("Google review");
    expect(page).not.toContain("Read it on Google");
    expect(page).toContain(`<a class="small" href="${LINK}" target="_blank" rel="noreferrer"`);
    expect(page).toContain("See all reviews on Google");
  });

  it("cut a long review only beside a link to read it on Google", () => {
    const long = "Really great work on the deck. ".repeat(40).trim();
    const page = html({ rating: 4.8, count: 120, reviews: [one({ text: long })], link: LINK, pdf: false });
    expect(page).toContain("…");
    expect(page).not.toContain(long);
    expect(page).toContain(`<a href="${LINK}" target="_blank" rel="noreferrer">Read it on Google</a>`);
    // One that fits is shown whole.
    const fits = "x".repeat(HUB_REVIEW_CHARS);
    expect(html({ rating: null, count: null, reviews: [one({ text: fits })], link: LINK, pdf: false })).toContain(fits);
  });

  it("leave out a review too long to show whole when there's nowhere to read the rest", () => {
    const long = "Really great work on the deck. ".repeat(40).trim();
    const page = html({ rating: 4.8, count: 120, reviews: [one({ name: "Long Winded", text: long }), one()], link: null, pdf: false });
    expect(page).not.toContain("Long Winded");
    expect(page).toContain("Dana Whitfield-Jones");
    expect(page).not.toContain("on Google</a>");
    // A link that isn't a plain https one is not used.
    expect(html({ rating: 4.8, count: 120, reviews: [one()], link: "javascript:alert(1)", pdf: false })).not.toContain("<a ");
  });

  it("show nothing without a rating or a review, and what an older server sends as it comes", () => {
    expect(html(null)).toBe("");
    expect(html({ rating: null, count: null, reviews: [], pdf: false })).toBe("");
    expect(html({ rating: null, count: 0, reviews: [one({ text: "x ".repeat(900) })], link: null, pdf: false })).toBe("");
    // Before the link was sent: the name and words the server had already shortened.
    const older = html({ rating: 4.8, count: 120, reviews: [one({ name: "Dana W.", text: "Great job…" })], pdf: false });
    expect(older).toContain("Dana W.");
    expect(older).toContain("Great job…");
  });
});
