/**
 * A showcase's public page (routes/showcases.ts): it's read only through public.showcase_view, which
 * answers only while it's published; the page says nothing of the client; its photos are served only
 * when they're the published showcase's own, from the copies made for the page; and none of it is
 * for search engines. The database answers what each test gives it.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { app } from "../src/app";
import type { Env } from "../src/env";
import { showcaseDraftPrompt } from "../src/routes/showcases";
import { tidyShowcaseCopies } from "../src/services/showcases";

const current = vi.hoisted(() => ({ db: null as unknown, files: {} as Record<string, Uint8Array> }));
vi.mock("../src/lib/supabase", async (original) => ({ ...(await original<typeof import("../src/lib/supabase")>()), adminClient: () => current.db, userClient: () => current.db }));
vi.mock("../src/lib/storedFile", () => ({ storedFile: async (_admin: unknown, path: string) => current.files[path] ?? null }));

const env: Env = { SUPABASE_URL: "https://example.supabase.co", SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test", SUPABASE_SECRET_KEY: "sb_secret_test", APP_URL: "https://jobly.example.com" };
const CO = "00000000-0000-4000-8000-0000000000c0";
const TOKEN = "0123456789abcdef0123456789abcdef";
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 0, 1, 0xff, 0xd9]);

type Answer = { data: unknown; error: null };
function fakeDb(view: unknown, tables: Record<string, unknown> = {}) {
  const rpcs: string[] = [];
  const chain = (table: string): unknown =>
    new Proxy({}, {
      get: (_, name) =>
        name === "then"
          ? (resolve: (v: Answer) => unknown) => resolve({ data: tables[table] ?? null, error: null })
          : () => chain(table),
    });
  current.db = {
    from: (table: string) => chain(table),
    rpc: async (name: string) => {
      rpcs.push(name);
      return { data: name === "rate_limit_hit" ? true : name === "showcase_view" ? view : null, error: null };
    },
  };
  return rpcs;
}

const published = {
  company_id: CO,
  title: "Driveway resealed",
  description: "Cracks filled and two coats down.",
  town: "Springfield",
  region: "IL",
  published_at: "2026-11-13T12:00:00Z",
  photos: [{ id: 7, role: "before" }, { id: 8, role: "after" }],
};

const get = (path: string) => app.request(`/api${path}`, {}, env);

afterEach(() => {
  current.files = {};
});

describe("a showcase's public page", () => {
  it("isn't there when it isn't published, and says so", async () => {
    fakeDb(null);
    const res = await get(`/public/showcases/${TOKEN}`);
    expect(res.status).toBe(404);
    expect(((await res.json()) as { error: string }).error).toBe("This showcase isn't available");
  });

  it("doesn't look up a link that can't be one", async () => {
    const rpcs = fakeDb(published);
    expect((await get("/public/showcases/not-a-token")).status).toBe(404);
    expect(rpcs).not.toContain("showcase_view");
  });

  it("shows the write-up, the town and the photos' own links, the company's look, and nothing of the client", async () => {
    fakeDb(published, {
      companies: { name: "Sketchy Gutters", phone: "(512) 555-0100", website: null, slug: "sketchy", settings: { branding: { color: "#225588" } } },
      intake_forms: { slug: "spring" },
    });
    const res = await get(`/public/showcases/${TOKEN}`);
    expect(res.status).toBe(200);
    expect(res.headers.get("X-Robots-Tag")).toBe("noindex");
    const body = (await res.json()) as Record<string, any>;
    expect(body).toMatchObject({
      title: "Driveway resealed",
      town: "Springfield, IL",
      company: { name: "Sketchy Gutters", color: "#225588" },
      photos: [{ role: "before", src: `/api/public/showcases/${TOKEN}/7.jpg` }, { role: "after", src: `/api/public/showcases/${TOKEN}/8.jpg` }],
      book_url: "/book/sketchy/spring",
    });
    const text = JSON.stringify(body);
    for (const word of ["client", "address", "line1", "company_id", "attachment"]) expect(text).not.toContain(word);
  });

  it("has no Get a quote without a booking form", async () => {
    fakeDb(published, { companies: { name: "Sketchy Gutters", phone: null, website: null, slug: "sketchy", settings: {} }, intake_forms: null });
    expect(((await (await get(`/public/showcases/${TOKEN}`)).json()) as { book_url: string | null }).book_url).toBeNull();
  });
});

describe("\"Write it with AI\" for a showcase", () => {
  it("sends the business, the services and the office's notes, and never the job's title", async () => {
    const prompt = showcaseDraftPrompt({ company: { name: "Sketchy Gutters", trade_preset: "roofing_exteriors" }, services: ["Gutter cleaning", "Downspout repair"], notes: "Clogged since the storm" });
    expect(prompt).toBe("Business: Sketchy Gutters (roofing exteriors).\nWork done: Gutter cleaning, Downspout repair\nNotes from the office: Clogged since the storm\n");
    expect(showcaseDraftPrompt({ company: { name: "Sketchy Gutters", trade_preset: "general" }, services: [] })).toBe("Business: Sketchy Gutters (general).\n");
    // A job's title is often the client's name ("Whitfield gutters"): the route doesn't even read it.
    const { readFileSync } = await import("node:fs");
    const route = readFileSync(new URL("../src/routes/showcases.ts", import.meta.url), "utf8");
    const draft = route.slice(route.indexOf('showcases.post("/showcases/draft"'), route.indexOf("/** The page's copy of one photo"));
    expect(draft).toContain('.from("jobs").select("client_id")');
    expect(draft).not.toMatch(/job\.title|select\("title/);
    expect(draft).toContain("prompt: showcaseDraftPrompt({ company, services, notes: body.notes })");
    // And a draft that names the client anyway is still refused.
    expect(draft).toContain("The AI's draft named the client. Try again, or write it yourself.");
  });
});

describe("a showcase's photos", () => {
  it("serves a published showcase's own copies, and no other photo", async () => {
    current.files[`${CO}/showcases/s1/copy.jpg`] = JPEG;
    fakeDb(published, { showcase_photos: { public_path: `${CO}/showcases/s1/copy.jpg` } });
    const ok = await get(`/public/showcases/${TOKEN}/7.jpg`);
    expect(ok.status).toBe(200);
    expect(ok.headers.get("Content-Type")).toBe("image/jpeg");
    expect(ok.headers.get("X-Robots-Tag")).toBe("noindex");
    expect(new Uint8Array(await ok.arrayBuffer())).toEqual(JPEG);
    expect((await get(`/public/showcases/${TOKEN}/9.jpg`)).status).toBe(404);
    expect((await get(`/public/showcases/${TOKEN}/7.png`)).status).toBe(404);
  });

  it("serves nothing once it's unpublished", async () => {
    current.files[`${CO}/showcases/s1/copy.jpg`] = JPEG;
    fakeDb(null, { showcase_photos: { public_path: `${CO}/showcases/s1/copy.jpg` } });
    expect((await get(`/public/showcases/${TOKEN}/7.jpg`)).status).toBe(404);
  });

  it("serves only a JPEG, whatever is stored there", async () => {
    current.files[`${CO}/showcases/s1/copy.jpg`] = new TextEncoder().encode("<html>not a photo</html>");
    fakeDb(published, { showcase_photos: { public_path: `${CO}/showcases/s1/copy.jpg` } });
    expect((await get(`/public/showcases/${TOKEN}/7.jpg`)).status).toBe(404);
  });
});

describe("copies that are no longer shown", () => {
  it("are deleted from storage once the database lists them, never one still on a page", async () => {
    const listed = [
      { id: 1, path: `${CO}/showcases/s1/gone-a.jpg` },
      { id: 2, path: `${CO}/showcases/s1/gone-b.jpg` },
      { id: 3, path: `${CO}/showcases/s2/still-shown.jpg` },
    ];
    const removed: string[] = [];
    const cleared: number[] = [];
    const admin = {
      from: (table: string) => ({
        select: () =>
          table === "stale_public_files"
            ? { order: () => ({ limit: async () => ({ data: listed.filter((r) => !cleared.includes(r.id)), error: null }) }) }
            : { in: async () => ({ data: [{ public_path: `${CO}/showcases/s2/still-shown.jpg` }], error: null }) },
        delete: () => ({ in: async (_column: string, ids: number[]) => (cleared.push(...ids), { error: null }) }),
      }),
      storage: { from: () => ({ remove: async (paths: string[]) => (removed.push(...paths), { error: null }) }) },
    };
    await expect(tidyShowcaseCopies(admin as never)).resolves.toBe(2);
    expect(removed).toEqual([`${CO}/showcases/s1/gone-a.jpg`, `${CO}/showcases/s1/gone-b.jpg`]);
    expect(cleared).toEqual([1, 2, 3]);
    // Nothing listed: nothing done.
    await expect(tidyShowcaseCopies(admin as never)).resolves.toBe(0);
  });
});
