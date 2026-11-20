/**
 * Google Places asked from the browser for How you compare (features/marketing/reviewPlaces.ts):
 * the right address, the key the map uses, only the fields shown, nothing done to the Referer, and
 * Google's refusals turned into words that say what to fix.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  checkPlacesKey,
  comparisonKey,
  DETAIL_FIELDS,
  KEY_CHECK_FIELDS,
  NOT_ANSWERING,
  NOT_REACHED,
  PLACE_GONE,
  placesProblem,
  PlacesProblem,
  readPlace,
  SEARCH_FIELDS,
  searchPlaces,
} from "../src/features/marketing/reviewPlaces";

type Sent = { url: string; init: RequestInit; headers: Record<string, string>; body: any };
/** Google, answering what the test gives. */
function google(reply: (sent: Sent) => Response | Promise<Response>) {
  const sent: Sent[] = [];
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: string, init: RequestInit = {}) => {
      const call = { url: String(url), init, headers: (init.headers ?? {}) as Record<string, string>, body: init.body ? JSON.parse(String(init.body)) : null };
      sent.push(call);
      return reply(call);
    }),
  );
  return sent;
}
const refusal = (status: number, error: object) => Response.json({ error }, { status });

beforeEach(() => vi.stubGlobal("location", { origin: "https://jobly.example.com" }));
afterEach(() => vi.unstubAllGlobals());

describe("the key", () => {
  it("is the one the measuring map uses in this browser: the company's own, else this Jobly's browser key", () => {
    expect(comparisonKey({ maps: { google_key: " AIzaOwn " } }, "AIzaInstance")).toBe("AIzaOwn");
    expect(comparisonKey({ maps: {} }, "AIzaInstance")).toBe("AIzaInstance");
    expect(comparisonKey({}, null)).toBeNull();
    expect(comparisonKey(null, null)).toBeNull();
  });
});

describe("what each request asks for", () => {
  it("names the tiers Google bills by: IDs only for the check, no ratings in a search, and a place's rating with its name, link and status", () => {
    // From Google's "FieldMask" lists (place-details and text-search, read 2026-11-14).
    expect(KEY_CHECK_FIELDS).toBe("places.id");
    expect(SEARCH_FIELDS).toBe("places.id,places.displayName,places.formattedAddress,places.googleMapsUri,places.attributions");
    expect(DETAIL_FIELDS).toBe("id,displayName,rating,userRatingCount,googleMapsUri,businessStatus,attributions");
    // Nothing the card doesn't show: no reviews, photos, phone numbers, hours or coordinates.
    for (const fields of [SEARCH_FIELDS, DETAIL_FIELDS]) expect(fields).not.toMatch(/reviews|photos|phone|hours|location|\*/i);
  });
});

describe("a search", () => {
  it("goes straight to Google's Text Search with the key and the fields shown, and reads each result", async () => {
    const sent = google(() =>
      Response.json({
        places: [
          { id: "ChIJ_rival", displayName: { text: "Rival Gutters" }, formattedAddress: "1 Elm St, Springfield, IL", googleMapsUri: "https://maps.google.com/?cid=1" },
          { id: "ChIJ_other", displayName: { text: "Other Gutters" }, googleMapsUri: "javascript:alert(1)" },
          { id: "ChIJ_nameless" },
          { displayName: { text: "No id" } },
        ],
      }),
    );
    expect(await searchPlaces("AIzaBrowser", "Rival Gutters near Springfield, IL")).toEqual([
      { place_id: "ChIJ_rival", name: "Rival Gutters", address: "1 Elm St, Springfield, IL", maps_url: "https://maps.google.com/?cid=1", providers: [] },
      { place_id: "ChIJ_other", name: "Other Gutters", address: null, maps_url: null, providers: [] },
    ]);
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toBe("https://places.googleapis.com/v1/places:searchText");
    expect(sent[0]!.init.method).toBe("POST");
    expect(sent[0]!.headers).toEqual({ "X-Goog-Api-Key": "AIzaBrowser", "X-Goog-FieldMask": SEARCH_FIELDS, "Content-Type": "application/json" });
    // The town is in the words searched for: no coordinates are sent, because none are kept.
    expect(sent[0]!.body).toEqual({ textQuery: "Rival Gutters near Springfield, IL", pageSize: 10 });
  });
});

describe("reading a place", () => {
  it("is one Place Details call for its name, rating, review count, Maps link and whether it's closed", async () => {
    const sent = google(() => Response.json({ id: "ChIJ_rival", displayName: { text: "Rival Gutters" }, rating: 4.4, userRatingCount: 51, googleMapsUri: "https://maps.google.com/?cid=1", businessStatus: "OPERATIONAL" }));
    expect(await readPlace("AIzaBrowser", "ChIJ_rival")).toEqual({ place_id: "ChIJ_rival", name: "Rival Gutters", rating: 4.4, ratings_total: 51, maps_url: "https://maps.google.com/?cid=1", closed: false, providers: [] });
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toBe("https://places.googleapis.com/v1/places/ChIJ_rival");
    expect(sent[0]!.init.method).toBe("GET");
    expect(sent[0]!.init.body).toBeUndefined();
    expect(sent[0]!.headers).toEqual({ "X-Goog-Api-Key": "AIzaBrowser", "X-Goog-FieldMask": DETAIL_FIELDS });
  });

  it("says when Google marks it permanently closed, and shows a place with no reviews yet as having none to show", async () => {
    google(() => Response.json({ id: "p", displayName: { text: "Shut Gutters" }, businessStatus: "CLOSED_PERMANENTLY" }));
    expect(await readPlace("k", "p")).toEqual({ place_id: "p", name: "Shut Gutters", rating: null, ratings_total: null, maps_url: null, closed: true, providers: [] });
  });

  it("reads who else's data Google says must be named with the place", async () => {
    google((call) => {
      const place = { id: "p", displayName: { text: "Rival Gutters" }, attributions: [{ provider: " Acme Listings ", providerUri: "https://acme.example/listing" }, { provider: "Plain Data", providerUri: "javascript:alert(1)" }, { providerUri: "https://nameless.example" }] };
      return call.url.endsWith(":searchText") ? Response.json({ places: [place] }) : Response.json(place);
    });
    const providers = [{ name: "Acme Listings", url: "https://acme.example/listing" }, { name: "Plain Data", url: null }];
    expect((await readPlace("k", "p")).providers).toEqual(providers);
    expect((await searchPlaces("k", "Rival Gutters"))[0]!.providers).toEqual(providers);
  });

  it("tells a place Google no longer lists from trouble with the key", async () => {
    google(() => refusal(404, { status: "NOT_FOUND", message: "Place not found." }));
    await expect(readPlace("k", "ChIJ_gone")).rejects.toMatchObject({ message: PLACE_GONE, place: true });
    google(() => refusal(400, { status: "INVALID_ARGUMENT", message: "Not a valid Place ID: ChIJ_old" }));
    await expect(readPlace("k", "ChIJ_old")).rejects.toMatchObject({ message: PLACE_GONE, place: true });
    google(() => Response.json({ id: "p" }));
    await expect(readPlace("k", "p")).rejects.toMatchObject({ message: PLACE_GONE, place: true });
    // The key refused, even with a 400: that's not the place's doing.
    google(() => refusal(400, { status: "INVALID_ARGUMENT", message: "API key not valid. Please pass a valid API key.", details: [{ reason: "API_KEY_INVALID" }] }));
    await expect(readPlace("k", "p")).rejects.toMatchObject({ place: false, message: expect.stringMatching(/didn't accept the key/) });
    google(() => refusal(403, { status: "PERMISSION_DENIED", message: "Requests from referer https://jobly.example.com/ are blocked.", details: [{ reason: "API_KEY_HTTP_REFERRER_BLOCKED" }] }));
    await expect(readPlace("k", "p")).rejects.toMatchObject({ place: false });
  });

  it("never asks Google about something that isn't a place ID", async () => {
    const sent = google(() => Response.json({}));
    for (const not of ["../admin", "places/ChIJ", "Rival Gutters", "a?b=c", ""]) await expect(readPlace("k", not)).rejects.toBeInstanceOf(PlacesProblem);
    expect(sent).toHaveLength(0);
  });
});

describe("the request itself", () => {
  it("leaves the Referer to the browser: no Referer header, no referrer or referrer policy set, nothing but the key, the fields and the content type", async () => {
    const sent = google((call) => (call.url.endsWith(":searchText") ? Response.json({ places: [] }) : Response.json({ id: "p", displayName: { text: "X" } })));
    await searchPlaces("AIzaBrowser", "x");
    await readPlace("AIzaBrowser", "p");
    await checkPlacesKey("AIzaBrowser", "Sketchy Gutters");
    expect(sent).toHaveLength(3);
    for (const { init, headers, url } of sent) {
      expect(Object.keys(headers).map((h) => h.toLowerCase()).filter((h) => !["x-goog-api-key", "x-goog-fieldmask", "content-type"].includes(h)), url).toEqual([]);
      expect(init, url).not.toHaveProperty("referrer");
      expect(init, url).not.toHaveProperty("referrerPolicy");
      // Nor a sign-in or a cookie: Google gets the key and the question.
      expect(init, url).not.toHaveProperty("credentials");
      // The browser isn't to keep Google's answer either.
      expect(init.cache, url).toBe("no-store");
      expect(new URL(url).origin).toBe("https://places.googleapis.com");
    }
  });
});

describe("checking a key before the comparison is turned on", () => {
  it("is a search for place IDs only, which Google doesn't charge for", async () => {
    const sent = google(() => Response.json({ places: [{ id: "p1" }] }));
    expect(await checkPlacesKey("AIzaBrowser", "  Sketchy Gutters ")).toBeNull();
    expect(sent[0]!.url).toBe("https://places.googleapis.com/v1/places:searchText");
    expect(sent[0]!.headers["X-Goog-FieldMask"]).toBe("places.id");
    expect(sent[0]!.body).toEqual({ textQuery: "Sketchy Gutters", pageSize: 1 });
    // A business nobody has reviewed yet is still a key that works.
    google(() => Response.json({}));
    expect(await checkPlacesKey("AIzaBrowser", "")).toBeNull();
  });

  it("says what to fix in plain words, whatever Google's own say", async () => {
    const said = async (status: number, error: object) => {
      google(() => refusal(status, error));
      return checkPlacesKey("AIzaBrowser", "Sketchy Gutters");
    };
    expect(await said(403, { status: "PERMISSION_DENIED", message: "Places API (New) has not been used in project 123 before or it is disabled.", details: [{ reason: "SERVICE_DISABLED" }] })).toBe(
      "The Google key's project doesn't have Places API (New) turned on. In Google Cloud, enable Places API (New) for it.",
    );
    expect(await said(403, { status: "PERMISSION_DENIED", message: "Requests from referer https://jobly.example.com/ are blocked.", details: [{ reason: "API_KEY_HTTP_REFERRER_BLOCKED" }] })).toBe(
      "The Google key is limited to other websites. In Google Cloud, add https://jobly.example.com to the key's website restrictions.",
    );
    expect(await said(403, { status: "PERMISSION_DENIED", message: "Requests to this API places.googleapis.com method google.maps.places.v1.Places.SearchText are blocked.", details: [{ reason: "API_KEY_SERVICE_BLOCKED" }] })).toMatch(
      /add Places API \(New\) to the key's API restrictions/,
    );
    expect(await said(400, { status: "INVALID_ARGUMENT", message: "API key not valid. Please pass a valid API key.", details: [{ reason: "API_KEY_INVALID" }] })).toMatch(/didn't accept the key.*Settings → Maps/);
    expect(await said(403, { status: "PERMISSION_DENIED", message: "The provided API key has an IP address restriction.", details: [{ reason: "API_KEY_IP_ADDRESS_BLOCKED" }] })).toMatch(/a web page can't use it/);
    expect(await said(403, { status: "PERMISSION_DENIED", message: "This API method requires billing to be enabled." })).toMatch(/billing account/);
    expect(await said(429, { status: "RESOURCE_EXHAUSTED", message: "Quota exceeded for quota metric 'SearchTextRequest'." })).toMatch(/used up its Places quota/);
    expect(await said(403, { status: "PERMISSION_DENIED", message: "Something new." })).toMatch(/Google refused the key for Places/);
    expect(await said(500, { status: "INTERNAL", message: "Backend error 0x7f" })).toBe(NOT_ANSWERING);
    // None of them hands Google's own technical words on.
    expect(placesProblem(403, { status: "PERMISSION_DENIED", message: "x", details: [{ reason: "SERVICE_DISABLED" }] })).not.toMatch(/SERVICE_DISABLED|PERMISSION_DENIED/);
    expect(placesProblem(404, { status: "NOT_FOUND", message: "Place not found." })).toBeNull();
  });

  it("says so when Google can't be reached, or answers something that isn't an answer", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => Promise.reject(new TypeError("Failed to fetch"))));
    expect(await checkPlacesKey("AIzaBrowser", "x")).toBe(NOT_REACHED);
    await expect(readPlace("AIzaBrowser", "p")).rejects.toMatchObject({ message: NOT_REACHED, place: false });
    vi.stubGlobal("fetch", vi.fn(async () => new Response("<html>Bad gateway</html>", { status: 502 })));
    expect(await checkPlacesKey("AIzaBrowser", "x")).toBe(NOT_ANSWERING);
  });
});
