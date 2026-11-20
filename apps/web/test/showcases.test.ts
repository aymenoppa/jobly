/**
 * Showcases outside the Showcases tab (features/marketing/showcaseWords.ts): a client's page says
 * they have one and what turning off photos does to it, and a showcase that came down by itself
 * says why.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath, URL } from "node:url";
import { describe, expect, it } from "vitest";
import { clientShowcaseWords, photoSwitchNote, takenDownWords } from "../src/features/marketing/showcaseWords";

const source = (path: string) => readFileSync(fileURLToPath(new URL(`../src/${path}`, import.meta.url)), "utf8");

describe("a client's showcases, on the client's page", () => {
  const live = { status: "published" };
  const down = { status: "unpublished" };
  const draft = { status: "draft" };

  it("says they have one, and whether it's up", () => {
    expect(clientShowcaseWords([])).toBe("");
    expect(clientShowcaseWords([live])).toBe("1 showcase, published");
    expect(clientShowcaseWords([draft])).toBe("1 showcase, not published");
    expect(clientShowcaseWords([live, down, live])).toBe("3 showcases, 2 published");
    expect(clientShowcaseWords([down, draft])).toBe("2 showcases, none published");
  });

  it("says, under the photos switch, that turning it off takes their published showcases down", () => {
    expect(photoSwitchNote([], false)).toBeNull();
    expect(photoSwitchNote([draft], false)).toBeNull();
    expect(photoSwitchNote([live], false)).toBe("Turning this off takes down their published showcase, pages anyone with the link can see.");
    expect(photoSwitchNote([live, live, draft], false)).toMatch(/their 2 published showcases/);
    expect(photoSwitchNote([down], true)).toBe("Their showcase is down and can't be published while this is off.");
    expect(photoSwitchNote([down, down], true)).toMatch(/showcases are down/);
  });

  it("is on the client's page, among their chips and under the switch", () => {
    const page = source("features/clients/ClientPage.tsx");
    expect(page).toContain("<ClientShowcaseChip clientId={c.id} />");
    expect(page).toContain("<ClientShowcaseNote clientId={c.id} optedOut={c.social_photos_opt_out} />");
    // And read again when the switch changes, since the database takes them down.
    expect(page).toContain('queryKey: ["client-showcases", id]');
  });
});

describe("a showcase that came down by itself", () => {
  it("says why, where the office looks for it", () => {
    expect(takenDownWords({ status: "unpublished", unpublished_reason: "the client asked that photos of their property not be posted" })).toBe("Taken down: the client asked that photos of their property not be posted");
    // Unpublished by someone, or published again since: nothing to explain.
    expect(takenDownWords({ status: "unpublished", unpublished_reason: null })).toBeNull();
    expect(takenDownWords({ status: "published", unpublished_reason: "one of its photos is no longer marked OK to share" })).toBeNull();
    expect(source("features/marketing/Showcases.tsx")).toContain("unpublished_reason");
  });
});
