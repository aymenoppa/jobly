/**
 * A postcard campaign's page (features/marketing/PostcardPage.tsx), the parts it works out before
 * drawing (features/marketing/postcardForm.ts): the preview's address block is Lob's own.
 */
import { readFileSync } from "node:fs";
import { fileURLToPath, URL } from "node:url";
import { describe, expect, it } from "vitest";
import { frontResolutionWarning, ONE_PER_ADDRESS } from "@jobly/core/postcards";
import { audienceAddress, audienceCsvRows, blockStyle, deletableFrom, draftAsSaved, duplicateQuestion, leftOutWords, needsAdmin, pickablePhotos, proofLink, proofQuestion, waitForSave, type AudienceRow } from "../src/features/marketing/postcardForm";
import { toCsv } from "../src/lib/csv";

describe("the photos offered for a postcard's front", () => {
  it("are only those the database says may be shown, and of those only the ones the person can open", () => {
    // What social_photos gives: marked OK to share, never an opted-out client's. `c` isn't readable by this person.
    const shared = [{ id: "b" }, { id: "a" }, { id: "c" }];
    // Their own read of attachments also holds `x`, which nobody marked OK to share.
    const readable = [{ id: "a", marked_path: null }, { id: "x", marked_path: null }, { id: "b", marked_path: "co/b-marked.jpg" }];
    expect(pickablePhotos(shared, readable)).toEqual([{ id: "b", marked_path: "co/b-marked.jpg" }, { id: "a", marked_path: null }]);
    expect(pickablePhotos([], readable)).toEqual([]);
  });

  it("come from the photos OK to share, never from every photo the company has", () => {
    const page = readFileSync(fileURLToPath(new URL("../src/features/marketing/PostcardPage.tsx", import.meta.url)), "utf8");
    const picker = page.slice(page.indexOf("function FrontPhotoPicker"), page.indexOf("export function PostcardPreview"));
    expect(picker).toContain('rpc("social_photos"');
    expect(picker).toContain("pickablePhotos(shared, readable)");
  });
});

describe("who gets a card, in full", () => {
  const rows: AudienceRow[] = [
    { client_id: "1", display_name: "Ann Oak", address: { line1: "12 Oak St", line2: "Apt 2", city: "Springfield", region: "IL", postal_code: "62701-1234" }, left_out: null },
    { client_id: "2", display_name: "Bea Elm", address: null, left_out: "bad_state" },
    { client_id: "3", display_name: "Cal Oak", address: { line1: "12 Oak St", line2: "Apt 2", city: "Springfield", region: "IL", postal_code: "62701" }, left_out: "same_address" },
    { client_id: "4", display_name: "=Dee Fir", address: { line1: "3 Fir Rd", city: "Peoria", region: "IL", postal_code: "61602" }, left_out: null },
  ];

  it("shows the whole address a card goes to, and why someone is left out", () => {
    expect(audienceAddress(rows[0]!)).toBe("12 Oak St, Apt 2, Springfield, IL 62701-1234");
    expect(audienceAddress(rows[1]!)).toBe("");
    expect(leftOutWords("bad_state")).toBe("a state that isn't a US state");
    expect(leftOutWords("same_address")).toBe("at an address another client's card goes to");
    expect(ONE_PER_ADDRESS).toMatch(/One card goes to each address.*longest/);
  });

  it("downloads as a spreadsheet: everyone who gets one with their address, then everyone left out with why", () => {
    const sheet = audienceCsvRows(rows);
    expect(sheet.rows.map((r) => `${r.name}|${r.gets}`)).toEqual(["Ann Oak|Yes", "=Dee Fir|Yes", "Bea Elm|No", "Cal Oak|No"]);
    expect(sheet.rows[0]).toEqual({ name: "Ann Oak", gets: "Yes", line1: "12 Oak St", line2: "Apt 2", city: "Springfield", state: "IL", zip: "62701-1234", why: "" });
    expect(sheet.rows[3]).toMatchObject({ gets: "No", line1: "12 Oak St", why: "at an address another client's card goes to" });
    const csv = toCsv(sheet.rows, sheet.columns);
    expect(csv.split("\r\n")[0]).toBe("Client,Gets a card,Address,Address line 2,City,State,ZIP,Why not");
    // A name that would run as a formula in a spreadsheet is written as text.
    expect(csv).toContain("'=Dee Fir,Yes,3 Fir Rd");
  });

  it("is read a page at a time, so a list past 1,000 clients is whole", () => {
    const dialog = readFileSync(fileURLToPath(new URL("../src/features/marketing/PostcardAudience.tsx", import.meta.url)), "utf8");
    expect(dialog).toMatch(/everyRow<AudienceRow>\(\(\) => supabase\(\)\.rpc\("postcard_audience"/);
  });
});

describe("Send waits for the draft to be saved", () => {
  it("is held back while a change is waiting to save or saving, and says why when the save failed", () => {
    expect(waitForSave("idle")).toEqual({ blocked: false, problem: null });
    expect(waitForSave("saved")).toEqual({ blocked: false, problem: null });
    expect(waitForSave("edited")).toEqual({ blocked: true, problem: null });
    expect(waitForSave("saving")).toEqual({ blocked: true, problem: null });
    const failed = waitForSave("error");
    expect(failed.blocked).toBe(true);
    expect(failed.problem).toMatch(/couldn't be saved, so sending now would mail the card as it was before/);
  });

  it("tells the server what the page shows, in the shape it's saved in, so the server can refuse a stale card", () => {
    const shown = draftAsSaved({ message: "Hi {{client.first_name}}", size: "6x9", front_attachment_id: null, front_marked: true, front_path: "co/postcards/c1/a.jpg", audience: { tags_any: ["vip"], cities: [], recurring: "any" as never } });
    expect(shown).toEqual({ message: "Hi {{client.first_name}}", size: "6x9", front_attachment_id: null, front_marked: true, front_path: "co/postcards/c1/a.jpg", audience: { tags_any: ["vip"] } });
    const page = readFileSync(fileURLToPath(new URL("../src/features/marketing/PostcardPage.tsx", import.meta.url)), "utf8");
    expect(page).toContain("draft: draftAsSaved(draft)");
    expect(page).toMatch(/disabled=\{[^}]*unsaved\.blocked\}/);
  });
});

describe("Mail one to us first", () => {
  it("says before a live card that it's a real one, mailed to the company and charged for, and that a test card isn't", () => {
    const live = proofQuestion("live", "1 Main St, Springfield, IL 62701");
    expect(live.title).toBe("Mail one card to your own address?");
    expect(live.body).toMatch(/mails it to 1 Main St, Springfield, IL 62701, and charges your Lob account for that one card.*No client is mailed/);
    const test = proofQuestion("test", "1 Main St, Springfield, IL 62701");
    expect(test.body).toMatch(/Nothing is printed or mailed, and nothing is charged/);
    expect(test.confirmLabel).toBe("Make one test card");
  });

  it("is offered beside Send, held back by the same save and the same problems with the card, but not by an empty audience", () => {
    const page = readFileSync(fileURLToPath(new URL("../src/features/marketing/PostcardPage.tsx", import.meta.url)), "utf8");
    expect(page).toMatch(/disabled=\{cardProblems\.length > 0 \|\| unsaved\.blocked \|\| !mode\} onClick=\{askForProof\}/);
    expect(page).toContain("`/postcards/${id}/proof`");
  });
});

describe("who may spend", () => {
  it("sends the office to an owner or admin when the key is live, and not when it's a test key", () => {
    expect(needsAdmin("live", false)).toBe(true);
    expect(needsAdmin("live", true)).toBe(false);
    expect(needsAdmin("test", false)).toBe(false);
    // A server from before this was asked doesn't say: the page doesn't guess, and the server decides at Send.
    expect(needsAdmin("live", undefined)).toBe(false);
    expect(needsAdmin(undefined, false)).toBe(false);
  });

  it("says plainly that a copy of a mailed campaign mails everyone again", () => {
    expect(duplicateQuestion({ status: "draft", mode: null, made: 0 })).toBeNull();
    const sent = duplicateQuestion({ status: "sent", mode: "live", made: 212 })!;
    expect(sent.body).toMatch(/212 clients have already been mailed this card\. Sending the copy mails everyone in the audience again, those already mailed too/);
    expect(duplicateQuestion({ status: "cancelled", mode: "live", made: 1 })!.body).toMatch(/1 client has already been mailed/);
    // A test campaign mailed no one, but its copy still goes to the whole audience.
    const test = duplicateQuestion({ status: "sent", mode: "test", made: 40 })!;
    expect(test.body).not.toMatch(/already been mailed this card/);
    expect(test.body).toMatch(/mails everyone in the audience again/);
    const page = readFileSync(fileURLToPath(new URL("../src/features/marketing/PostcardPage.tsx", import.meta.url)), "utf8");
    expect(page).toContain('"Duplicate (mails everyone again)"');
  });
});

describe("a campaign after it's sent", () => {
  const DAY = 86_400_000;
  const now = Date.parse("2026-11-20T12:00:00Z");

  it("can't be deleted until a week after its last card, while Lob may still fetch its picture", () => {
    const sent = { status: "sent", started_at: "2026-11-18T10:00:00Z", finished_at: "2026-11-18T10:05:00Z", made_count: 40, failed_count: 1 };
    expect(deletableFrom(sent, now)?.toISOString()).toBe("2026-11-25T10:05:00.000Z");
    expect(deletableFrom(sent, now + 6 * DAY)).toBeNull();
    // Stopped part-way: from when it stopped. A draft, or one none of whose cards reached Lob, any time.
    expect(deletableFrom({ ...sent, status: "cancelled" }, now)).not.toBeNull();
    expect(deletableFrom({ ...sent, status: "draft" }, now)).toBeNull();
    expect(deletableFrom({ ...sent, made_count: 0, failed_count: 0 }, now)).toBeNull();
  });

  it("links to Lob's picture of a card only while Lob's link still works", () => {
    const card = { proof_url: "https://lob-assets.com/postcards/psc_1.pdf?sig=abc", proof_at: "2026-11-18T10:00:00Z" };
    expect(proofLink(card, now)).toBe(card.proof_url);
    expect(proofLink(card, now + 29 * DAY)).toBeNull();
    expect(proofLink({ proof_url: null, proof_at: null }, now)).toBeNull();
    expect(proofLink({ proof_url: "javascript:alert(1)", proof_at: card.proof_at }, now)).toBeNull();
  });
});

describe("the picture on the front", () => {
  it("is measured, and the page says when it's below what Lob asks for at the size chosen", () => {
    const page = readFileSync(fileURLToPath(new URL("../src/features/marketing/PostcardPage.tsx", import.meta.url)), "utf8");
    expect(page).toContain("frontResolutionWarning(shown.size, frontSize.data)");
    expect(page).toMatch(/\{soft && <div className="callout callout-warning"/);
    // A job photo (2,000 pixels at most) on the biggest card: the numbers are said.
    expect(frontResolutionWarning("6x11", { width: 2000, height: 1500 })).toMatch(/2,000 × 1,500 pixels.*about 177 dots per inch.*at least 300.*3,375 × 1,875 pixels/);
  });
});

describe("the preview of a postcard's back", () => {
  // Lob's templates, on the cut card: the block's size, 0.15 in from the right and 0.125 in from the bottom.
  const LOB = { "4x6": { card: [6, 4], block: [3.2835, 2.375] }, "6x9": { card: [9, 6], block: [4, 2.375] }, "6x11": { card: [11, 6], block: [4, 2.375] } } as const;

  it("draws Lob's address block where Lob prints it, at each size", () => {
    for (const size of ["4x6", "6x9", "6x11"] as const) {
      const style = blockStyle(size);
      const [left, top, width, height] = [style.left, style.top, style.width, style.height].map((v) => Number(v.replace("in", "")));
      expect(style.left.endsWith("in")).toBe(true);
      expect([width, height]).toEqual([...LOB[size].block]);
      expect(LOB[size].card[0] - (left! + width!)).toBeCloseTo(0.15, 4);
      expect(LOB[size].card[1] - (top! + height!)).toBeCloseTo(0.125, 4);
    }
  });
});
