/**
 * Photos drawn on, as they're stored (lib/photoMarkup.ts): the drawing is a new file beside the
 * photo, never the photo itself; screens show the drawing with a link to the original; saving
 * uploads it and then points the photo's row at it, and takes the file back off when the row
 * can't take it; taking the drawing off leaves the original.
 */
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";

const server = vi.hoisted(() => ({
  files: new Map<string, number>(),
  rows: new Map<string, { id: string; path: string; marked_path: string | null; marks?: unknown }>(),
  /** The row can't be read just now. */
  offline: false,
  removed: [] as string[],
  /** The row isn't the person's to change (attachments_update). */
  refuse: false,
  updates: [] as Array<Record<string, unknown>>,
}));

vi.mock("../src/lib/api", () => ({
  unwrap: (r: { data: unknown; error: { message: string } | null }) => {
    if (r.error) throw new Error(r.error.message);
    return r.data;
  },
  supabase: () => ({
    storage: {
      from: () => ({
        upload: async (path: string, body: Blob) => {
          server.files.set(path, body.size);
          return { data: { path }, error: null };
        },
        remove: async (paths: string[]) => {
          server.removed.push(...paths);
          paths.forEach((p) => server.files.delete(p));
          return { data: null, error: null };
        },
        download: async (path: string) => (server.files.has(path) ? { data: new Blob([new Uint8Array(server.files.get(path)!)]), error: null } : { data: null, error: { message: "Object not found" } }),
        createSignedUrls: async (paths: string[]) => ({ data: paths.filter((p) => server.files.has(p)).map((p) => ({ path: p, signedUrl: `https://files.test/${p}?token=1` })), error: null }),
      }),
    },
    from: () => ({
      select: () => ({
        eq: (_k: string, id: string) => ({
          limit: async () => (server.offline ? { data: null, error: { message: "Failed to fetch" } } : { data: server.rows.has(id) ? [{ ...server.rows.get(id)! }] : [], error: null }),
        }),
      }),
      update: (values: Record<string, unknown>) => ({
        eq: (_k: string, id: string) => ({
          select: async () => {
            server.updates.push(values);
            const row = server.rows.get(id);
            if (!row || server.refuse) return { data: [], error: null };
            Object.assign(row, values);
            return { data: [{ id }], error: null };
          },
        }),
      }),
    }),
  }),
}));

const { markedPathFor, photoLinks, photoPaths, photoPicture, photoToDrawOn, removeMarkup, saveMarkup, shownPath } = await import("../src/lib/photoMarkup");
const { packMarks } = await import("@jobly/core/photoMarkup");
type Mark = import("@jobly/core/photoMarkup").Mark;

const ORIGINAL = "c1/visit/v1/aa000000-0000-0000-0000-000000000001.jpg";
beforeEach(() => {
  server.files.clear();
  server.rows.clear();
  server.removed = [];
  server.updates = [];
  server.refuse = false;
  server.offline = false;
  server.files.set(ORIGINAL, 3000);
  server.rows.set("p1", { id: "p1", path: ORIGINAL, marked_path: null });
});

describe("where a drawing is kept", () => {
  it("is a new file in the photo's own folder, never the photo itself, a new name each time", () => {
    const first = markedPathFor(ORIGINAL);
    expect(first).toMatch(/^c1\/visit\/v1\/[0-9a-f-]{36}\.jpg$/);
    expect(first).not.toBe(ORIGINAL);
    expect(markedPathFor(ORIGINAL)).not.toBe(first);
    // A client's file merged from another client stays in that client's folder, and so does its drawing.
    expect(markedPathFor("c1/client/old/x.png")).toMatch(/^c1\/client\/old\/[0-9a-f-]{36}\.jpg$/);
  });
});

describe("what a photo shows", () => {
  it("is its drawing when it has one, else the photo as taken", () => {
    expect(shownPath({ path: ORIGINAL, marked_path: null })).toBe(ORIGINAL);
    expect(shownPath({ path: ORIGINAL })).toBe(ORIGINAL);
    expect(shownPath({ path: ORIGINAL, marked_path: "c1/visit/v1/m.jpg" })).toBe("c1/visit/v1/m.jpg");
  });

  it("links both, in one round, each file once", async () => {
    server.files.set("c1/visit/v1/m.jpg", 2000);
    expect(photoPaths([{ path: "a" }, { path: "b", marked_path: "m" }, { path: "a" }])).toEqual(["a", "b", "m"]);
    const [plain, drawn] = await photoLinks([{ path: ORIGINAL, marked_path: null, id: "p1" }, { path: ORIGINAL, marked_path: "c1/visit/v1/m.jpg", id: "p2" }]);
    expect(plain).toEqual({ id: "p1", path: ORIGINAL, marked_path: null, url: `https://files.test/${ORIGINAL}?token=1`, originalUrl: `https://files.test/${ORIGINAL}?token=1` });
    expect(drawn!.url).toBe("https://files.test/c1/visit/v1/m.jpg?token=1");
    expect(drawn!.originalUrl).toBe(`https://files.test/${ORIGINAL}?token=1`);
  });

  it("falls back to the photo as taken when its drawing can't be found", async () => {
    const [p] = await photoLinks([{ path: ORIGINAL, marked_path: "c1/visit/v1/gone.jpg" }]);
    expect(p!.url).toBe(`https://files.test/${ORIGINAL}?token=1`);
  });
});

describe("saving a drawing on a photo that's up", () => {
  it("uploads it beside the photo and points the photo at it, leaving the photo as it was", async () => {
    const path = await saveMarkup({ id: "p1", path: ORIGINAL }, new Blob([new Uint8Array(1200)], { type: "image/jpeg" }));
    expect(server.rows.get("p1")).toEqual({ id: "p1", path: ORIGINAL, marked_path: path, marks: null });
    expect(server.files.get(path)).toBe(1200);
    expect(server.files.get(ORIGINAL)).toBe(3000);
  });

  it("takes the file back off when the photo isn't theirs to change, and says why", async () => {
    server.refuse = true;
    await expect(saveMarkup({ id: "p1", path: ORIGINAL }, new Blob(["x"]))).rejects.toThrow("You can draw on photos you added. Ask the office to draw on this one.");
    expect(server.removed).toHaveLength(1);
    expect([...server.files.keys()]).toEqual([ORIGINAL]);
    expect(server.rows.get("p1")!.marked_path).toBeNull();
  });

  it("opens the photo to draw on as the person, and says plainly when it can't", async () => {
    expect((await photoPicture(ORIGINAL)).size).toBe(3000);
    await expect(photoPicture("c1/visit/v1/missing.jpg")).rejects.toThrow("This photo couldn't be opened. Check your signal and try again.");
  });
});

describe("drawing on a photo again", () => {
  const BOX: Mark = { kind: "box", color: "#e5243b", width: "thin", from: { x: 10, y: 10 }, to: { x: 200, y: 150 } };
  const ARROW: Mark = { kind: "arrow", color: "#e5243b", width: "thick", from: { x: 300, y: 300 }, to: { x: 500, y: 400 } };
  const size = { width: 2000, height: 1500 };
  const jpeg = (bytes: number) => new Blob([new Uint8Array(bytes)], { type: "image/jpeg" });

  it("keeps the marks with the drawing, and opens the photo as taken with them the next time, however often it's drawn on", async () => {
    // Nobody has drawn on it: the photo itself.
    const first = await photoToDrawOn({ id: "p1", path: ORIGINAL, marked_path: null });
    expect(first).toMatchObject({ original: true });
    expect(first.marks).toBeUndefined();
    expect(first.picture.size).toBe(3000);

    const drawing = await saveMarkup({ id: "p1", path: ORIGINAL }, jpeg(1200), (path) => packMarks([BOX], size, path));
    expect(server.rows.get("p1")!.marks).toMatchObject({ v: 1, for: drawing, marks: [BOX] });

    // Drawn on again: the original (3000 bytes), never the flattened drawing (1200), with the box still a mark.
    const second = await photoToDrawOn({ id: "p1", path: ORIGINAL, marked_path: drawing });
    expect(second.original).toBe(true);
    expect(second.picture.size).toBe(3000);
    expect(second.marks).toEqual({ saved: server.rows.get("p1")!.marks, path: drawing });

    const again = await saveMarkup({ id: "p1", path: ORIGINAL }, jpeg(1300), (path) => packMarks([BOX, ARROW], size, path));
    const third = await photoToDrawOn({ id: "p1", path: ORIGINAL, marked_path: again });
    expect(third.picture.size).toBe(3000);
    expect((third.marks!.saved as { marks: Mark[] }).marks).toEqual([BOX, ARROW]);
  });

  it("goes by the row as it is now, not the list on screen", async () => {
    const drawing = await saveMarkup({ id: "p1", path: ORIGINAL }, jpeg(1200), (path) => packMarks([BOX], size, path));
    // The screen still thinks it shows an older drawing.
    const opened = await photoToDrawOn({ id: "p1", path: ORIGINAL, marked_path: "c1/visit/v1/older.jpg" });
    expect(opened.marks?.path).toBe(drawing);
  });

  it("opens the drawing itself, and keeps no marks over it, when its marks weren't kept or are another drawing's", async () => {
    // Drawn on before marks were kept.
    server.files.set("c1/visit/v1/m.jpg", 2000);
    server.rows.get("p1")!.marked_path = "c1/visit/v1/m.jpg";
    const old = await photoToDrawOn({ id: "p1", path: ORIGINAL, marked_path: "c1/visit/v1/m.jpg" });
    expect(old).toMatchObject({ original: false });
    expect(old.picture.size).toBe(2000);
    expect(old.marks).toBeUndefined();

    // Marks kept, then an app from before this drew on it again: a new drawing, the old marks left behind.
    const drawing = await saveMarkup({ id: "p1", path: ORIGINAL }, jpeg(1200), (path) => packMarks([BOX], size, path));
    server.files.set("c1/visit/v1/by-old-app.jpg", 1700);
    server.rows.get("p1")!.marked_path = "c1/visit/v1/by-old-app.jpg";
    const stale = await photoToDrawOn({ id: "p1", path: ORIGINAL, marked_path: "c1/visit/v1/by-old-app.jpg" });
    expect(stale.original).toBe(false);
    expect(stale.picture.size).toBe(1700);
    expect(drawing).not.toBe("c1/visit/v1/by-old-app.jpg");

    // Saved with no marks (the editor keeps none over a flattened drawing): none are left to mislead the next time.
    await saveMarkup({ id: "p1", path: ORIGINAL }, jpeg(1800));
    expect(server.rows.get("p1")!.marks).toBeNull();
  });

  it("still opens what the photo shows when the row can't be read", async () => {
    server.files.set("c1/visit/v1/m.jpg", 2000);
    server.offline = true;
    const opened = await photoToDrawOn({ id: "p1", path: ORIGINAL, marked_path: "c1/visit/v1/m.jpg" });
    expect(opened).toMatchObject({ original: false });
    expect(opened.picture.size).toBe(2000);
  });
});

describe("taking a drawing off", () => {
  it("points the photo back at the original (the database puts the drawing in the Trash)", async () => {
    server.rows.get("p1")!.marked_path = "c1/visit/v1/m.jpg";
    await removeMarkup({ id: "p1" });
    expect(server.rows.get("p1")!.marked_path).toBeNull();
    expect(server.updates).toEqual([{ marked_path: null, marks: null }]);
  });

  it("says so when the photo isn't theirs to change", async () => {
    server.refuse = true;
    await expect(removeMarkup({ id: "p1" })).rejects.toThrow("You can change photos you added.");
  });
});

describe("the editor's layout", () => {
  const css = readFileSync(new URL("../src/styles/components.css", import.meta.url), "utf8");
  const rule = (selector: string) => css.split("\n").find((line) => line.startsWith(`${selector} {`)) ?? "";

  it("gives the photo what the bars leave: a column whose stage takes the rest, never a row sized by the photo", () => {
    expect(rule(".photo-editor[open]")).toContain("flex-direction: column");
    expect(rule(".photo-editor-bar")).toContain("flex: none");
    const stage = rule(".photo-editor-stage");
    expect(stage).toContain("flex: 1 1 0");
    expect(stage).toContain("min-height: 0");
    expect(stage).toContain("position: relative");
    // A grid here sizes its row by the canvas, and the canvas's "100%" then means its own height: the photo was cut off.
    for (const selector of [".photo-editor", ".photo-editor[open]", ".photo-editor-stage", ".photo-editor-stage canvas"]) expect(rule(selector)).not.toContain("grid");
  });

  it("places the canvas against the stage's own box, and the editor sizes it to fit", () => {
    const canvas = rule(".photo-editor-stage canvas");
    expect(canvas).toContain("position: absolute");
    expect(canvas).toContain("max-width: calc(100% - 16px)");
    expect(canvas).toContain("max-height: calc(100% - 16px)");
    const editor = readFileSync(new URL("../src/components/PhotoEditor.tsx", import.meta.url), "utf8");
    expect(editor).toContain("fitInside(size, room)");
    expect(editor).toContain("ResizeObserver");
  });
});
