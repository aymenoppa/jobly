/**
 * "What clients say on Google" on a quote in the Client Hub: the business's Google rating and
 * count, and up to three of its Google reviews (the server's quoteReviewsFor picks them), when it
 * shows them on quotes (Marketing → Reviews). They're Google's, shown as Google has them: the
 * reviewer's name and their words unchanged, a long review cut only beside a link to read it on
 * Google, and a link to the business's profile there. Nothing without any.
 */
import { fitReviews, HUB_REVIEW_CHARS } from "@jobly/core/reviews";
import { formatDate } from "@/lib/format";
import type { HubReviews as Reviews } from "./document";

export function HubReviews({ reviews }: { reviews: Reviews | null | undefined }) {
  if (!reviews) return null;
  const link = /^https:\/\//.test(reviews.link ?? "") ? reviews.link! : null;
  const shown = fitReviews(reviews.reviews, HUB_REVIEW_CHARS, link);
  if (!shown.length && !reviews.count) return null;
  return (
    <section className="card card-pad stack-sm" aria-labelledby="hub-reviews">
      <h2 id="hub-reviews" className="hub-step-title">What clients say on Google</h2>
      {reviews.rating !== null && Boolean(reviews.count) && (
        <span>
          <span style={{ color: "var(--req)" }} aria-hidden="true">★</span> <strong>{reviews.rating.toFixed(1)}</strong> on Google ·{" "}
          {reviews.count!.toLocaleString("en-US")} {reviews.count === 1 ? "review" : "reviews"}
        </span>
      )}
      {shown.map((r, i) => (
        <figure key={i} className="stack-sm" style={{ gap: 2, margin: 0, paddingTop: 10, borderTop: "1px solid var(--divider)" }}>
          <span role="img" aria-label={`${r.rating} out of 5 stars`} style={{ color: "var(--req)", letterSpacing: 1 }}>{"★".repeat(r.rating)}</span>
          <blockquote style={{ margin: 0, whiteSpace: "pre-line", overflowWrap: "anywhere" }}>
            {r.text}
            {r.cut && link && <> <a href={link} target="_blank" rel="noreferrer">Read it on Google</a></>}
          </blockquote>
          <figcaption className="muted small">{r.name} · {formatDate(r.date)} · Google review</figcaption>
        </figure>
      ))}
      {link && (
        <a className="small" href={link} target="_blank" rel="noreferrer" style={{ paddingTop: 10, borderTop: "1px solid var(--divider)" }}>
          See all reviews on Google
        </a>
      )}
    </section>
  );
}
