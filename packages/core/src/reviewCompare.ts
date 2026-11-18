/**
 * How you compare (Marketing → Reviews): the business's Google rating and review count next to up to
 * five competitors', read from Google in the browser when someone asks and kept nowhere. Only each
 * place's Google ID is saved (apps/api/src/services/reviewCompare.ts says why). Shared by the API
 * and the card: what a place ID looks like, how many competitors, Google's own words to show with
 * its content, and where the business stands among the places just read.
 */

/**
 * What Google's Places API policies ask to be shown with its content, in its own words
 * (developers.google.com/maps/documentation/places/web-service/policies, read 2026-11-14): the
 * attribution "Google Maps" where its content is shown without a map; with reviews and average
 * ratings, its notice about them and a link to its policy with this label; and with search results,
 * what decides their order. Not to be reworded, translated or re-capitalised.
 */
export const GOOGLE_ATTRIBUTION = "Google Maps";
export const GOOGLE_REVIEW_NOTICE = "Reviews aren't verified by Google, but Google checks for and removes fake content when it's identified.";
export const GOOGLE_REVIEW_POLICY_LABEL = "Learn more about Google Maps user-generated content policy";
export const GOOGLE_REVIEW_POLICY_URL = "https://support.google.com/contributionpolicy/answer/7422880";
export const GOOGLE_SEARCH_NOTICE =
  "When searching for businesses or places near a location, Google Maps will show local results. Several factors — primarily relevance, distance and prominence — are combined to help find the best results for a search.";
export const GOOGLE_SEARCH_NOTICE_LABEL = "Learn more";
export const GOOGLE_SEARCH_NOTICE_URL = "https://support.google.com/maps/answer/3092445?&ref_topic=3092444#zippy=%2Cwithin-google-maps%2Cother-google-products";

export const MAX_COMPETITORS = 5;

/**
 * A Google place ID, the one thing about a place that may be saved: letters, digits, hyphens and
 * underscores. The database holds place_id to the same shape.
 */
export const PLACE_ID = /^[A-Za-z0-9_-]{1,300}$/;

/** A place as Google just described it. Held by the card while it's on the screen, never saved. */
export interface ComparedPlace {
  id: string;
  name: string;
  is_own: boolean;
  rating: number | null;
  ratings_total: number | null;
}

/** Places best first: the higher rating, then more reviews, then the name; places with no rating last. */
export function ranked<T extends Pick<ComparedPlace, "name" | "rating" | "ratings_total">>(places: readonly T[]): T[] {
  return [...places].sort(
    (a, b) => (b.rating ?? -1) - (a.rating ?? -1) || (b.ratings_total ?? -1) - (a.ratings_total ?? -1) || a.name.localeCompare(b.name),
  );
}

export interface Standing {
  /** 1 for the best rating. */
  rank: number;
  of: number;
  /** The business's rating less the competitors' average, to one decimal; null without both. */
  ratingVsAverage: number | null;
  /** The business's reviews less the competitors' average, whole; null without both. */
  reviewsVsAverage: number | null;
}

const average = (values: number[]) => (values.length ? values.reduce((s, v) => s + v, 0) / values.length : null);

/** Where the business stands among the places read, or null without its own place or any competitor read. */
export function standing(places: readonly ComparedPlace[]): Standing | null {
  const own = places.find((p) => p.is_own);
  const others = places.filter((p) => !p.is_own);
  if (!own || own.rating == null || !others.some((p) => p.rating != null)) return null;
  const order = ranked(places.filter((p) => p.rating != null));
  const ratings = others.map((p) => p.rating).filter((r): r is number => r != null);
  const counts = others.map((p) => p.ratings_total).filter((n): n is number => n != null);
  const avgRating = average(ratings);
  const avgCount = average(counts);
  return {
    rank: order.findIndex((p) => p.id === own.id) + 1,
    of: order.length,
    ratingVsAverage: avgRating == null ? null : Math.round((own.rating - avgRating) * 10) / 10,
    reviewsVsAverage: avgCount == null || own.ratings_total == null ? null : Math.round(own.ratings_total - avgCount),
  };
}

/** "Highest rated of 4", "2nd of 4 by rating". */
export function standingWords(s: Pick<Standing, "rank" | "of">): string {
  if (s.rank === 1) return `Highest rated of ${s.of}`;
  const suffix = s.rank % 100 >= 11 && s.rank % 100 <= 13 ? "th" : ({ 1: "st", 2: "nd", 3: "rd" } as Record<number, string>)[s.rank % 10] ?? "th";
  return `${s.rank}${suffix} of ${s.of} by rating`;
}
