/**
 * Google reviews in Jobly (docs/marketing-plan.md, phase D): the Google Business Profile app
 * brings one location's reviews in (apps/api/src/services/googleReviews.ts), each matched to a client
 * by name when only one fits, and Marketing → Reviews shows them with their numbers and replies.
 * Shared by the API and the web. The database matches with the same rules and folds names the same
 * way (private.name_key and private.review_match, supabase/migrations/20261031000300_google_reviews.sql).
 */
import { localDate } from "./time";

// ---------------------------------------------------------------------------------------------
// Stars
// ---------------------------------------------------------------------------------------------

/** Google's v4 API sends a review's stars as words. */
export const STAR_RATINGS = { ONE: 1, TWO: 2, THREE: 3, FOUR: 4, FIVE: 5 } as const;
export type Stars = 1 | 2 | 3 | 4 | 5;

/** "FIVE" → 5. STAR_RATING_UNSPECIFIED, or anything else, is null: a review with no stars. */
export function starRating(value: unknown): Stars | null {
  return typeof value === "string" && Object.hasOwn(STAR_RATINGS, value) ? STAR_RATINGS[value as keyof typeof STAR_RATINGS] : null;
}

/** "4 out of 5 stars", for screen readers and the review list. */
export const starsLabel = (n: number) => `${n} out of 5 stars`;

/** 1 and 2 stars: these come first in the office's email, and only these go by email. */
export const isLowRating = (rating: number | null | undefined) => rating != null && rating <= 2;

// ---------------------------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------------------------

/**
 * Letters folded to plain ones before names are compared, upper and lower case both, so the
 * database's locale never changes the answer. `to` is shorter than `from`: the rest of `from`
 * (apostrophes and accents typed as separate marks) is dropped, as translate() drops it.
 */
export const NAME_FOLDS = {
  pairs: [["ß", "ss"], ["ẞ", "ss"], ["æ", "ae"], ["Æ", "ae"], ["œ", "oe"], ["Œ", "oe"]] as ReadonlyArray<readonly [string, string]>,
  from:
    "ÀàÁáÂâÃãÄäÅåĀāĂăĄąÇçĆćĈĉĊċČčĎďĐđÈèÉéÊêËëĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħÌìÍíÎîÏïĨĩĪīĬĭĮįıĴĵĶķĹĺĻļĽľĿŀŁłÑñŃńŅņŇňÒòÓóÔôÕõÖöØøŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšȘșŢţŤťŦŧȚțÙùÚúÛûÜüŨũŪūŬŭŮůŰűŲųŴŵÝýŸÿŶŷŹźŻżŽžİABCDEFGHIJKLMNOPQRSTUVWXYZ" +
    "'’‘ʼ`̧̨̀́̂̃̄̆̇̈̊̋̌",
  to: "aaaaaaaaaaaaaaaaaaccccccccccddddeeeeeeeeeeeeeeeeeegggggggghhhhiiiiiiiiiiiiiiiiijjkkllllllllllnnnnnnnnoooooooooooooooooorrrrrrssssssssssttttttttuuuuuuuuuuuuuuuuuuuuwwyyyyyyzzzzzziabcdefghijklmnopqrstuvwxyz",
} as const;

const FOLD = (() => {
  const from = [...NAME_FOLDS.from];
  const to = [...NAME_FOLDS.to];
  return new Map(from.map((ch, i) => [ch, to[i] ?? ""]));
})();

/**
 * A name as matching compares it: composed, folded, apostrophes dropped, anything else that isn't a
 * plain letter or digit a space, spaces run together. "O’Brien-Núñez, Éric" → "obrien nunez eric".
 * Null when nothing is left.
 */
export function nameKey(name: string | null | undefined): string | null {
  let text = (name ?? "").normalize("NFC");
  for (const [letter, plain] of NAME_FOLDS.pairs) text = text.split(letter).join(plain);
  const folded = [...text].map((ch) => FOLD.get(ch) ?? ch).join("");
  const key = folded.replace(/[^abcdefghijklmnopqrstuvwxyz0123456789]+/g, " ").trim();
  return key || null;
}

/** A client's name as Google shortens a reviewer's: "Ana Maria Smith" → "ana s". Null for one word. */
export function nameShort(name: string | null | undefined): string | null {
  const words = nameKey(name)?.split(" ") ?? [];
  if (words.length < 2) return null;
  return `${words[0]} ${words.at(-1)!.charAt(0)}`;
}

/**
 * A reviewer's name to match on: the whole name, or `short` when Google shows "Ana S." (a first name
 * and one letter). Null for an anonymous reviewer, who is never matched.
 */
export function reviewerKey(name: string | null | undefined, anonymous: boolean): { key: string; short: boolean } | null {
  if (anonymous) return null;
  const key = nameKey(name);
  if (!key) return null;
  const words = key.split(" ");
  return { key, short: words.length === 2 && words[1]!.length === 1 };
}

/** How a reviewer's name fits a client's: their whole name, the "Ana S." form, or not at all. */
export function nameMatch(reviewer: { name: string | null | undefined; anonymous: boolean }, client: { display_name: string }): "full" | "short" | null {
  const r = reviewerKey(reviewer.name, reviewer.anonymous);
  if (!r) return null;
  if (r.short) return nameShort(client.display_name) === r.key ? "short" : null;
  return nameKey(client.display_name) === r.key ? "full" : null;
}

/** A review is matched with a client asked for one in this many days before it. */
export const REVIEW_MATCH_DAYS = 180;
/** Why a matched client's reminders stopped (review_requests.reminder_note). */
export const REVIEW_STOP_NOTE = "Left a Google review";

/** A client whose name fits a review: how, whether they were asked within REVIEW_MATCH_DAYS, and whether another review already has them. */
export interface MatchCandidate {
  id: string;
  how: "full" | "short";
  asked: boolean;
  taken?: boolean;
}

/**
 * The client a review is matched to automatically, as private.review_match picks one: of the
 * clients not matched to another review, the one asked for a review lately when exactly one was;
 * with none asked, the one whose whole name fits when exactly one does. A "First L." name needs an
 * ask. Anything else stays unmatched for the office to match by hand.
 */
export function pickMatch(candidates: readonly MatchCandidate[]): string | null {
  const open = candidates.filter((c) => !c.taken);
  const asked = open.filter((c) => c.asked);
  if (asked.length) return asked.length === 1 ? asked[0]!.id : null;
  const full = open.filter((c) => c.how === "full");
  return full.length === 1 ? full[0]!.id : null;
}

// ---------------------------------------------------------------------------------------------
// Telling the office
// ---------------------------------------------------------------------------------------------

/** A new review tells the office only when it was posted this lately (and after the first full sync). */
export const NOTIFY_WITHIN_DAYS = 14;

/**
 * Whether a review just brought in for the first time tells the office: once the first full sync
 * has finished (so connecting doesn't announce every old review) and it was posted lately. The
 * database decides the same way (record_reviews).
 */
export function shouldNotify(postedAt: string | Date, at: { firstSyncedAt: string | Date | null; now?: Date }): boolean {
  if (!at.firstSyncedAt) return false;
  const now = at.now ?? new Date();
  return new Date(postedAt).getTime() > now.getTime() - NOTIFY_WITHIN_DAYS * 86_400_000;
}

export interface NoticeReview {
  reviewer_name: string | null;
  reviewer_anonymous: boolean;
  rating: number | null;
  comment: string | null;
}

/** The name to call a reviewer by, or null for an anonymous one or one Google sent without a name. */
export const reviewerName = (review: { reviewer_name: string | null; reviewer_anonymous: boolean }) =>
  review.reviewer_anonymous || !review.reviewer_name?.trim() ? null : review.reviewer_name.trim();

const reviewerWords = (review: NoticeReview) => reviewerName(review) ?? "Someone";
const starWords = (n: number) => `${n} ${n === 1 ? "star" : "stars"}`;

/**
 * The office's notification for a review, as claim_review_notices writes it: "Ana S. left a 2-star
 * review", or for one changed down to 1 or 2 stars, "Ana S. changed their review to 1 star". Low
 * ratings are kind review_low, which also goes by email.
 */
export function reviewNotice(review: NoticeReview, lowered = false): { kind: "review" | "review_low"; title: string; body: string | null } {
  const who = reviewerWords(review);
  const title = lowered && review.rating
    ? `${who} changed their review to ${starWords(review.rating)}`
    : review.rating ? `${who} left a ${review.rating}-star review` : `${who} left a review`;
  const text = review.comment?.replace(/\s+/g, " ").trim() ?? "";
  const body = text ? (text.length > 200 ? `${text.slice(0, 199).trimEnd()}…` : text) : review.rating ? "No comment, just stars." : null;
  return { kind: isLowRating(review.rating) ? "review_low" : "review", title, body };
}

// ---------------------------------------------------------------------------------------------
// The Reviews tab's numbers
// ---------------------------------------------------------------------------------------------

/** One month of review_stats().months, in the company's time zone. */
export interface ReviewMonth {
  month: string;
  count: number;
  rating_sum: number;
  rated: number;
}

export interface TrendMonth {
  /** "2026-10" */
  month: string;
  /** "Oct" */
  label: string;
  /** "October 2026" */
  title: string;
  count: number;
  /** Null for a month with no stars to average, never 0. */
  average: number | null;
}

/** The 12 months up to and including this one in the company's time zone, each filled in. */
export function reviewTrend(months: readonly ReviewMonth[], now: Date, timeZone: string): TrendMonth[] {
  const [year, month] = localDate(now, timeZone).split("-").map(Number) as [number, number];
  const byMonth = new Map(months.map((m) => [m.month, m]));
  const out: TrendMonth[] = [];
  for (let back = 11; back >= 0; back--) {
    const date = new Date(Date.UTC(year, month - 1 - back, 1, 12));
    const key = date.toISOString().slice(0, 7);
    const row = byMonth.get(key);
    const rated = Number(row?.rated ?? 0);
    out.push({
      month: key,
      label: date.toLocaleDateString("en-US", { month: "short", timeZone: "UTC" }),
      title: date.toLocaleDateString("en-US", { month: "long", year: "numeric", timeZone: "UTC" }),
      count: Number(row?.count ?? 0),
      average: rated ? Math.round((Number(row!.rating_sum) / rated) * 10) / 10 : null,
    });
  }
  return out;
}

/** The share of reviews with a reply, as a whole percent, or null with no reviews. */
export const responseRate = (replied: number, total: number): number | null => (total > 0 ? Math.round((replied / total) * 100) : null);

/**
 * "12 min", "5 hours", "2 days", "3 weeks": short enough for a stat card's big number on one line,
 * where the hint says it's the usual time. Null when there's nothing to say.
 */
export function replyTimeWords(hours: number | null | undefined): string | null {
  if (hours == null || !Number.isFinite(hours) || hours < 0) return null;
  if (hours < 1) return `${Math.max(1, Math.round(hours * 60))} min`;
  if (hours < 23.5) {
    const n = Math.round(hours);
    return `${n} ${n === 1 ? "hour" : "hours"}`;
  }
  const days = Math.round(hours / 24);
  if (days < 14) return `${days} ${days === 1 ? "day" : "days"}`;
  return `${Math.round(days / 7)} weeks`;
}

/** Google takes replies of up to 4,096 characters. */
export const REPLY_MAX = 4096;

// ---------------------------------------------------------------------------------------------
// Google's approval, and other problems
// ---------------------------------------------------------------------------------------------

/** Where whoever owns the Google Cloud project asks Google for access to the Business Profile APIs. */
export const GOOGLE_ACCESS_FORM = "https://developers.google.com/my-business/content/prereqs";
export const APPROVAL_MESSAGE = "Google hasn't approved this server's access to reviews yet.";
export const OWN_APP_APPROVAL_MESSAGE = "Google hasn't approved your Google app's access to reviews yet.";
export const NOT_ENABLED_MESSAGE = "The Business Profile APIs aren't turned on in this server's Google Cloud project yet.";
export const SIGNIN_MESSAGE = "Google sign-in expired. Reconnect Google Business Profile in Apps.";

/**
 * What's in the way of bringing reviews in (review_syncs.problem): Google hasn't approved access, its
 * APIs aren't turned on, the sign-in expired, a location to pick, something about the location, or
 * another error. `detail` says which location problem it is.
 */
export type ReviewProblem = "approval" | "not_enabled" | "signin" | "pick" | "location" | "error";
export type LocationProblem = "unverified" | "suspended" | "no_access" | "gone";

/** The words for a location problem, as the app page and the Reviews tab say it. */
export const LOCATION_PROBLEMS: Record<LocationProblem, string> = {
  unverified: "Google says this location isn't verified yet. Verify it in Google Business Profile, then Check again.",
  suspended: "Google has suspended this location, so its reviews can't be brought in. Google Business Profile says what to do.",
  no_access: "The Google account you signed in with can't manage this location anymore. Reconnect with an owner or manager of the profile, or pick another location.",
  gone: "This location isn't in the Google account anymore. Pick it again, or another one.",
};

// ---------------------------------------------------------------------------------------------
// Fresh reviews (20261113001860_google_reviews_kept_while_fresh.sql)
// ---------------------------------------------------------------------------------------------

/**
 * A review is a copy of what's on Google, kept and shown only while the sync keeps seeing it there:
 * for this many days after it last did (reviews.seen_at). 29, so the tidy that runs once a day never
 * leaves a copy past 30. The database's policy and tidy_reviews use the same number, and a test
 * compares them.
 */
export const REVIEW_FRESH_DAYS = 29;

/** The time a review must have been seen on Google since, to be shown or reused anywhere. */
export const reviewsFreshSince = (now: Date | number = Date.now()): string => new Date(Number(now) - REVIEW_FRESH_DAYS * 86_400_000).toISOString();

/** Whether something last heard from Google at `at` (a review's seen_at, a sync's last_synced_at) is still fresh. */
export const isFresh = (at: string | null | undefined, now: Date | number = Date.now()): boolean => Boolean(at) && Date.parse(at!) > Number(now) - REVIEW_FRESH_DAYS * 86_400_000;

// ---------------------------------------------------------------------------------------------
// Reviews shown on quotes (settings.quote_reviews, 20261113001130_reviews_on_quotes.sql)
// ---------------------------------------------------------------------------------------------

/**
 * How many reviews a quote shows, and how many characters of each one's words there's room for: in
 * the Client Hub, and on the quote's PDF (a printed page). A longer review is cut there only beside
 * a link to read all of it on Google (fitReviews).
 */
export const QUOTE_REVIEWS = 3;
export const HUB_REVIEW_CHARS = 600;
export const PDF_REVIEW_CHARS = 280;

/** A Google review as the server reads it for a quote (public.reviews). */
export interface QuoteReviewRow {
  reviewer_name: string | null;
  reviewer_anonymous: boolean;
  rating: number | null;
  comment: string | null;
  posted_at: string;
  /** 1 to 3: picked by the office in Marketing → Reviews, in this order. */
  quote_pick?: number | null;
  /** Taken off Google: never shown. */
  deleted_at?: string | null;
}

/** A review as a quote carries it: the reviewer's name and their words as they are on Google. */
export interface QuoteReview {
  name: string;
  rating: number;
  date: string;
  text: string;
}

/** The reviewer as Google names them, unchanged; "A Google user" for an anonymous one, or when Google gave no name. */
export const reviewerDisplayName = (review: { reviewer_name: string | null; reviewer_anonymous: boolean }): string => reviewerName(review) ?? "A Google user";

/**
 * A review's words where there's room for `max` characters: all of them when they fit, else the
 * start, ending at a word with "…". Nothing else about them changes (line breaks stay), and a cut
 * one is only shown with a link to the whole review on Google.
 */
export function cutReview(text: string | null | undefined, max: number): { text: string; cut: boolean } {
  const whole = (text ?? "").trim();
  if (whole.length <= max) return { text: whole, cut: false };
  const start = whole.slice(0, max - 1);
  const space = start.search(/\s\S*$/);
  return { text: `${(space > max / 2 ? start.slice(0, space) : start).replace(/[\s.,;:!?-]+$/, "")}…`, cut: true };
}

/**
 * The reviews as a layout with room for `max` characters of each shows them. A review too long to
 * show whole is cut, when there's a link to read it on Google; with no link it's left out, so a
 * review is never shown shortened with nowhere to read the rest.
 */
export function fitReviews<T extends { text: string }>(reviews: readonly T[], max: number, link: string | null | undefined): Array<T & { cut: boolean }> {
  return reviews.flatMap((r) => {
    const fitted = cutReview(r.text, max);
    return fitted.cut && !link ? [] : [{ ...r, ...fitted }];
  });
}

/**
 * The link to a business's profile on Google Maps, where its reviews can be read: the one Google
 * gives for the location, else one made from its place ID the way Google's Maps URLs are written.
 * Null when Google gave neither.
 */
export function profileLink(location: { maps_uri?: string | null; place_id?: string | null; title?: string | null }): string | null {
  if (location.maps_uri && /^https:\/\//.test(location.maps_uri)) return location.maps_uri;
  if (!location.place_id) return null;
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(location.title?.trim() || "Google")}&query_place_id=${encodeURIComponent(location.place_id)}`;
}

/**
 * The reviews a quote shows: the ones the office picked, in their order; when none of those is still
 * on Google, the newest with 5 stars and words. Three at most, each with the reviewer's name and
 * words as Google has them. None at all when there are none to show.
 */
export function quoteReviews(rows: readonly QuoteReviewRow[]): QuoteReview[] {
  const live = rows.filter((r) => !r.deleted_at && r.rating != null && r.rating >= 1 && r.rating <= 5);
  const picked = live.filter((r) => r.quote_pick != null).sort((a, b) => a.quote_pick! - b.quote_pick!);
  const chosen = picked.length
    ? picked
    : live.filter((r) => r.rating === 5 && (r.comment ?? "").trim()).sort((a, b) => Date.parse(b.posted_at) - Date.parse(a.posted_at));
  return chosen.slice(0, QUOTE_REVIEWS).map((r) => ({ name: reviewerDisplayName(r), rating: r.rating!, date: r.posted_at.slice(0, 10), text: (r.comment ?? "").trim() }));
}

/** The Google Cloud project number in an OAuth client ID ("123456789012-abc.apps.googleusercontent.com"), which Google's access form asks for. */
export function projectNumber(clientId: string | null | undefined): string | null {
  return /^(\d{6,})-/.exec(clientId ?? "")?.[1] ?? null;
}
