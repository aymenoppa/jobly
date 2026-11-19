/**
 * How you compare (ReviewCompare.tsx): what the card knows and does, apart from drawing it.
 *
 * Two kinds of thing, kept apart on purpose:
 *
 *   Saved      The switch and the list of places, each by Google's ID for it and whether it's the
 *              business itself. That's all Jobly's server is ever sent or keeps (the four calls
 *              below), because a place ID is all Google's terms let an application keep.
 *   Readings   What Google just said about each place (reviewPlaces.ts): its name, rating, number
 *              of reviews and Maps link. They live in the card's own memory while it's on the
 *              screen and nowhere else: not the server, not this browser's storage, not the saved
 *              copy of screens crews get offline (lib/offline.ts), not React Query. Leave the page
 *              and they're gone; Compare now reads them again.
 *
 * apps/web/test/reviewCompare.test.ts fails if either rule is broken.
 */
import { MAX_COMPETITORS, ranked, standing, type ComparedPlace, type Standing } from "@jobly/core/reviewCompare";
import { api, ApiError } from "@/lib/api";
import { checkPlacesKey, PlacesProblem, type FoundPlace, type LivePlace, type Provider } from "./reviewPlaces";

/** A place on the card as Jobly keeps it: Google's ID for it, and whether it's the business itself. */
export interface SavedPlace {
  id: string;
  place_id: string;
  is_own: boolean;
}

export interface CompareState {
  enabled: boolean;
  places: SavedPlace[];
  can_switch: boolean;
}

// ---------------------------------------------------------------------------------------------
// Jobly's server: the switch and the place IDs. Nothing Google said goes in any of these.
// ---------------------------------------------------------------------------------------------

export const loadComparison = () => api.get<CompareState>("/reviews/compare");
export const switchComparison = (enabled: boolean) => api.put<CompareState>("/reviews/compare/enabled", { enabled });
export const savePlace = (placeId: string, own: boolean) => api.post<Omit<CompareState, "can_switch">>("/reviews/compare/places", { place_id: placeId, own });
export const removePlace = (id: string) => api.delete<Omit<CompareState, "can_switch">>(`/reviews/compare/places/${id}`);

export const NO_KEY = "Add a Google key in Settings → Maps first, with Places API (New) turned on for it.";

/**
 * Turning the comparison on. The key is checked with Google from this browser first (a search for
 * the business's name asking for place IDs only, which Google doesn't charge for); when Google
 * refuses, the switch stays off and the error says what to fix.
 */
export async function turnOn(key: string | null, companyName: string): Promise<CompareState> {
  if (!key) throw new ApiError(NO_KEY, 400);
  const problem = await checkPlacesKey(key, companyName);
  if (problem) throw new ApiError(problem, 400);
  return switchComparison(true);
}

// ---------------------------------------------------------------------------------------------
// Readings: Google's answers, in memory.
// ---------------------------------------------------------------------------------------------

/**
 * What the card knows about a saved place right now, by its place ID. No entry: not read yet.
 *   read    Google's figures, from the last Compare now.
 *   named   Picked from a search this visit, or read before the Compare now that's running: its
 *           name is known, its figures aren't.
 *   gone    Google no longer lists it.
 */
export type Reading =
  | { status: "read"; name: string; maps_url: string | null; providers: Provider[]; rating: number | null; ratings_total: number | null; closed: boolean }
  | { status: "named"; name: string; maps_url: string | null; providers: Provider[] }
  | { status: "gone" };
export type Readings = Readonly<Record<string, Reading>>;

/** A place just picked from a search: its name shows at once, its figures at the next Compare now. */
export const withFound = (readings: Readings, found: Pick<FoundPlace, "place_id" | "name" | "maps_url" | "providers">): Readings =>
  readings[found.place_id]?.status === "read" ? readings : { ...readings, [found.place_id]: { status: "named", name: found.name, maps_url: found.maps_url, providers: found.providers } };

/** Only the places still on the card: what was read about one that's been removed is dropped. */
export const forSaved = (readings: Readings, places: readonly SavedPlace[]): Readings =>
  Object.fromEntries(places.flatMap((p) => (readings[p.place_id] ? [[p.place_id, readings[p.place_id]!]] : [])));

/** As a Compare now starts: figures from the time before go, so the table never mixes two readings. */
const withoutFigures = (readings: Readings): Readings =>
  Object.fromEntries(Object.entries(readings).flatMap(([id, r]) => (r.status === "gone" ? [] : [[id, { status: "named" as const, name: r.name, maps_url: r.maps_url, providers: r.providers }]])));

export interface ComparisonRun {
  readings: Readings;
  /** Places Google answered about, listed or not. None: nothing was read, and nothing to wait for. */
  answered: number;
  /** Why it stopped before the end, in words that say what to fix. */
  problem: string | null;
}

/**
 * Compare now: each saved place read from Google, one Place Details call apiece, in order. A place
 * Google no longer lists is marked and the rest are still read. Trouble with the key itself stops
 * the run where it is: the next place would get the same answer, and might be charged for it.
 */
export async function runComparison(
  places: readonly SavedPlace[],
  read: (placeId: string) => Promise<LivePlace>,
  before: Readings = {},
  onProgress: (readings: Readings) => void = () => undefined,
): Promise<ComparisonRun> {
  let readings = withoutFigures(forSaved(before, places));
  let answered = 0;
  onProgress(readings);
  for (const place of places) {
    try {
      const live = await read(place.place_id);
      readings = { ...readings, [place.place_id]: { status: "read", name: live.name, maps_url: live.maps_url, providers: live.providers, rating: live.rating, ratings_total: live.ratings_total, closed: live.closed } };
    } catch (failure) {
      if (!(failure instanceof PlacesProblem)) throw failure;
      if (!failure.place) return { readings, answered, problem: failure.message };
      readings = { ...readings, [place.place_id]: { status: "gone" } };
    }
    answered++;
    onProgress(readings);
  }
  return { readings, answered, problem: null };
}

// ---------------------------------------------------------------------------------------------
// What the card shows.
// ---------------------------------------------------------------------------------------------

export interface CompareRow {
  id: string;
  place_id: string;
  is_own: boolean;
  status: "unread" | Reading["status"];
  /** Google's name for the place once it's known; until then "Your business" or "Competitor 2". */
  label: string;
  /** The label is Google's name, so it's shown as Google's content. */
  fromGoogle: boolean;
  maps_url: string | null;
  /** Other data providers Google names for this place, to be shown with it. */
  providers: Provider[];
  rating: number | null;
  ratings_total: number | null;
  closed: boolean;
}

/**
 * The card's rows: the business itself first, then the competitors just read, best rated first,
 * then the ones still to be read (or gone) in the order they were added.
 */
export function compareRows(places: readonly SavedPlace[], readings: Readings): CompareRow[] {
  let n = 0;
  const rows = places.map((p): CompareRow => {
    const r = readings[p.place_id];
    const fallback = p.is_own ? "Your business" : `Competitor ${++n}`;
    const known = r && r.status !== "gone" ? r : null;
    return {
      id: p.id,
      place_id: p.place_id,
      is_own: p.is_own,
      status: r?.status ?? "unread",
      label: known?.name ?? fallback,
      fromGoogle: Boolean(known),
      maps_url: known?.maps_url ?? null,
      providers: known?.providers ?? [],
      rating: r?.status === "read" ? r.rating : null,
      ratings_total: r?.status === "read" ? r.ratings_total : null,
      closed: r?.status === "read" && r.closed,
    };
  });
  const others = rows.filter((r) => !r.is_own);
  const read = ranked(others.filter((r) => r.status === "read").map((row) => ({ name: row.label, rating: row.rating, ratings_total: row.ratings_total, row })));
  return [...rows.filter((r) => r.is_own), ...read.map((r) => r.row), ...others.filter((r) => r.status !== "read")];
}

/** Whether anything of Google's is on the screen, which is when its attribution and notice must be too. */
export const showsGoogle = (rows: readonly CompareRow[]) => rows.some((r) => r.fromGoogle);

/** Every other data provider Google names for what's on the screen, once each, to go beside "Google Maps". */
export const providersOn = (shown: ReadonlyArray<{ providers: readonly Provider[] }>): Provider[] => [...new Map(shown.flatMap((s) => s.providers).map((p) => [p.name, p])).values()];

/** Where the business stands among the places just read. One Google marks closed for good isn't competition. */
export function standingOf(rows: readonly CompareRow[]): Standing | null {
  const read = rows.filter((r) => r.status === "read" && (r.is_own || !r.closed));
  return standing(read.map((r): ComparedPlace => ({ id: r.id, name: r.label, is_own: r.is_own, rating: r.rating, ratings_total: r.ratings_total })));
}

/** Whether another competitor fits, and whether the business itself is on the card yet. */
export const roomLeft = (places: readonly SavedPlace[]) => ({
  hasOwn: places.some((p) => p.is_own),
  full: places.filter((p) => !p.is_own).length >= MAX_COMPETITORS,
});

// ---------------------------------------------------------------------------------------------
// Each Compare now is paid Place Details calls on the company's key, so it can't be pressed over
// and over: not while one is running, and not for a minute after. Only the time of the last one is
// remembered, in memory, so leaving the tab and coming back doesn't get round it.
// ---------------------------------------------------------------------------------------------

export const COOLDOWN_MS = 60_000;
const lastCompared = new Map<string, number>();

export const noteCompared = (companyId: string, now = Date.now()) => void lastCompared.set(companyId, now);
/** When Compare now can next be pressed, as a time in milliseconds; 0 when nothing has been compared yet. */
export const comparableAt = (companyId: string) => (lastCompared.has(companyId) ? lastCompared.get(companyId)! + COOLDOWN_MS : 0);
/** Whether the button is live: there are places and a key to ask with, nothing is running, and the minute is up. */
export const canCompare = (o: { places: number; running: boolean; waiting: boolean; key: string | null }) => o.places > 0 && !o.running && !o.waiting && Boolean(o.key);

// ---------------------------------------------------------------------------------------------
// Searching. "Near" is the company's own town and state, typed into the search: no coordinates are
// looked up or kept.
// ---------------------------------------------------------------------------------------------

type Address = { city?: string | null; region?: string | null } | null | undefined;

/** "Springfield, IL", from the company's address in Settings → Company; "" without one. */
export const townOf = (address: Address) => [address?.city, address?.region].map((part) => (part ?? "").trim()).filter(Boolean).join(", ");

/** "Acme Paving near Springfield, IL", or the name alone when the company has no town. */
export const searchText = (name: string, address: Address) => {
  const town = townOf(address);
  return town ? `${name.trim()} near ${town}` : name.trim();
};

/** "landscaping near Springfield, IL": businesses of the company's trade in its town, or null without a town. */
export function tradeSearchText(tradePreset: string | null | undefined, address: Address): string | null {
  const town = townOf(address);
  if (!town) return null;
  const trade = !tradePreset || tradePreset === "general" ? "contractor" : tradePreset.replace(/_/g, " ");
  return `${trade} near ${town}`;
}

/** Search results worth offering: not the places already on the card. */
export const notYetAdded = (found: readonly FoundPlace[], places: readonly SavedPlace[]) => {
  const have = new Set(places.map((p) => p.place_id));
  return found.filter((f) => !have.has(f.place_id));
};
