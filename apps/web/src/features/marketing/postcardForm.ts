/**
 * What a postcard campaign's page (PostcardPage.tsx) works out before it draws anything, kept apart
 * from the page so it can be tested: where the preview draws Lob's address block.
 */
import { audienceKeys, type CampaignAudience } from "@jobly/core/campaigns";
import { addressBlock, addressLine, BLEED_IN, LEFT_OUT_WORDS, LOB_PROOF_DAYS, POSTCARD_KEEP_DAYS, type LeftOut, type PostcardSize } from "@jobly/core/postcards";

/**
 * The photos offered for a card's front: those the database says may be shown (`shared`, from
 * public.social_photos: marked OK to share, never of a client who said not to post photos of their
 * property), in its order, and of those only the ones the person looking can open themselves
 * (`readable`, their own read of attachments, which also says whether a photo has a drawn-on copy).
 */
export function pickablePhotos<S extends { id: string }, R extends { id: string }>(shared: readonly S[], readable: readonly R[]): R[] {
  const mine = new Map(readable.map((photo) => [photo.id, photo]));
  return shared.map((photo) => mine.get(photo.id)).filter((photo): photo is R => photo !== undefined);
}

/** A client in a draft's audience, as public.postcard_audience gives them: the address their card goes to, or why they're left out. */
export interface AudienceRow {
  client_id: string;
  display_name: string;
  address: { line1?: string; line2?: string | null; city?: string; region?: string; postal_code?: string } | null;
  left_out: string | null;
}

/** The address a card goes to, on one line, or "" without one. */
export const audienceAddress = (row: Pick<AudienceRow, "address">) =>
  row.address?.line1 ? addressLine({ line1: row.address.line1, line2: row.address.line2, city: row.address.city ?? "", region: row.address.region ?? "", postal_code: row.address.postal_code ?? "" }) : "";

/** Why a client is left out, in words: "Left out: no complete mailing address". */
export const leftOutWords = (reason: string) => LEFT_OUT_WORDS[reason as LeftOut] ?? "not mailed";

/**
 * The whole audience as a spreadsheet, to check before spending: everyone who gets a card with the
 * address it goes to, then everyone left out with why.
 */
export function audienceCsvRows(rows: readonly AudienceRow[]): { rows: Array<Record<string, string>>; columns: Array<{ key: string; label: string }> } {
  const columns = [
    { key: "name", label: "Client" },
    { key: "gets", label: "Gets a card" },
    { key: "line1", label: "Address" },
    { key: "line2", label: "Address line 2" },
    { key: "city", label: "City" },
    { key: "state", label: "State" },
    { key: "zip", label: "ZIP" },
    { key: "why", label: "Why not" },
  ];
  const line = (r: AudienceRow) => ({
    name: r.display_name,
    gets: r.left_out ? "No" : "Yes",
    line1: r.address?.line1 ?? "",
    line2: r.address?.line2 ?? "",
    city: r.address?.city ?? "",
    state: r.address?.region ?? "",
    zip: r.address?.postal_code ?? "",
    why: r.left_out ? leftOutWords(r.left_out) : "",
  });
  return { rows: [...rows.filter((r) => !r.left_out), ...rows.filter((r) => r.left_out)].map(line), columns };
}

/**
 * Whether the person looking has to ask an owner or admin to send: the key is live, which spends
 * the company's money, and the server says they may not (`canSendLive` false). With a test key, or
 * before the server has said, they aren't sent away; the server refuses a live Send from them anyway.
 */
export const needsAdmin = (mode: "test" | "live" | null | undefined, canSendLive: boolean | undefined) => mode === "live" && canSendLive === false;

export const ASK_ADMIN_WORDS = "The Lob key is a live one, so sending mails real cards and Lob charges for each. You can get the campaign ready and see who it goes to; an owner or admin presses Send.";

/**
 * What to ask before copying a campaign, or null when there's nothing to ask (a draft's copy is
 * just another draft). A copy keeps the audience, so sending it mails the same people again: there
 * is no "only the ones who didn't get one".
 */
export function duplicateQuestion(c: { status: string; mode: string | null; made: number }): { title: string; body: string } | null {
  if (c.status === "draft") return null;
  const mailed = c.mode === "live" && c.made > 0 ? `${c.made.toLocaleString("en-US")} ${c.made === 1 ? "client has" : "clients have"} already been mailed this card. ` : "";
  return {
    title: "Copy this campaign?",
    body: `The copy is a new draft with the same card and the same audience. ${mailed}Sending the copy mails everyone in the audience again, those already mailed too: narrow who it goes to first if that isn't what you want. Nothing is mailed until the copy is sent.`,
  };
}

/**
 * Whether Send has to wait for the draft to be saved. The page saves a little after each change;
 * Send mails what's saved, so until the change on screen is saved (or if saving it failed) Send
 * would mail the card as it was before. `problem` says so when the save failed; while a save is
 * only pending, Send just waits.
 */
export function waitForSave(status: "idle" | "edited" | "saving" | "saved" | "error"): { blocked: boolean; problem: string | null } {
  if (status === "error") return { blocked: true, problem: "Your last changes couldn't be saved, so sending now would mail the card as it was before them. Check your connection, then change something to save again." };
  return { blocked: status === "edited" || status === "saving", problem: null };
}

/**
 * The card and audience as the page shows them, in the shape they're saved in, sent along with
 * Send: the server mails nothing when this isn't what's saved.
 */
export function draftAsSaved(d: { message: string; size: string; front_attachment_id: string | null; front_marked: boolean; front_path: string | null; audience: CampaignAudience }) {
  return { message: d.message, size: d.size, front_attachment_id: d.front_attachment_id, front_marked: d.front_marked, front_path: d.front_path, audience: audienceKeys(d.audience) as Record<string, unknown> };
}

/**
 * What's asked before one card of the draft is made for the company's own address: with a live key
 * it's a real card, printed, mailed and charged for; with a test key Lob only draws it.
 */
export function proofQuestion(mode: "test" | "live", address: string): { title: string; body: string; confirmLabel: string } {
  return mode === "live"
    ? {
        title: "Mail one card to your own address?",
        body: `Lob prints one card and mails it to ${address}, and charges your Lob account for that one card. It's the card a client would get, with your name in place of theirs, so you can hold it before the campaign goes out. No client is mailed.`,
        confirmLabel: "Mail one card",
      }
    : {
        title: "Make one test card?",
        body: `Lob makes one test card addressed to ${address}, so you can see exactly how Lob draws it. Nothing is printed or mailed, and nothing is charged.`,
        confirmLabel: "Make one test card",
      };
}

const DAY = 86_400_000;

/** Lob's link to its picture of a card, while it still works (30 days from when Lob gave it), else null. */
export function proofLink(r: { proof_url?: string | null; proof_at?: string | null }, now = Date.now()): string | null {
  if (!r.proof_url || !r.proof_at || !r.proof_url.startsWith("https://")) return null;
  return now - Date.parse(r.proof_at) < LOB_PROOF_DAYS * DAY ? r.proof_url : null;
}

/**
 * The day a sent or stopped campaign can be deleted, or null when it can be now. Lob fetches the
 * front's picture from this server while it draws the cards, and deleting the campaign takes the
 * picture down, so it stays for POSTCARD_KEEP_DAYS days after the last card (the database refuses
 * a delete before then too). A campaign none of whose cards reached Lob has nothing to keep.
 */
export function deletableFrom(c: { status: string; started_at: string | null; finished_at: string | null; made_count: number; failed_count: number }, now = Date.now()): Date | null {
  if (c.status === "draft" || c.made_count + c.failed_count === 0) return null;
  const last = Date.parse(c.finished_at ?? c.started_at ?? "");
  if (!Number.isFinite(last)) return null;
  const from = last + POSTCARD_KEEP_DAYS * DAY;
  return from > now ? new Date(from) : null;
}

/**
 * Where the preview draws Lob's address block on the back: Lob's own block for the size
 * (addressBlock, on the artwork with its bleed), placed on the cut card the preview shows.
 */
export function blockStyle(size: PostcardSize): { left: string; top: string; width: string; height: string } {
  const block = addressBlock(size);
  const inches = (value: number) => `${Math.round(value * 10_000) / 10_000}in`;
  return { left: inches(block.left - BLEED_IN), top: inches(block.top - BLEED_IN), width: inches(block.width), height: inches(block.height) };
}
