/**
 * What a receipt dropped in with others (ReceiptDrafts) is and says, apart from being read: with
 * reading switched off it simply waits to be filled in, which is not a failure; and when it couldn't
 * even be sent to be read (a server from before this, no connection), it says why instead of
 * sitting at "Reading…". The office's alone, so these lines are in English for now.
 */
import { ApiError } from "@/lib/errors";

/** A draft still being read after this long was cut off (a server restart): it can be read again. */
export const STUCK_MS = 3 * 60_000;

/**
 * Where a draft is:
 *   reading   sent to be read, and not long ago
 *   read      read: its details show, to check and save
 *   to_fill   not read because reading is off: to fill in by hand. Nothing went wrong.
 *   waiting   its turn hasn't come: the hour's reading allowance is used up. Read when there's room.
 *   failed    reading it was tried and didn't work (its error says why), or was cut off
 */
export type DraftState = "reading" | "read" | "to_fill" | "waiting" | "failed";

export function draftState(draft: { status: string; created_at: string; updated_at?: string | null }, now: number): DraftState {
  if (draft.status === "to_fill" || draft.status === "waiting") return draft.status;
  // Since it was last sent to be read: when it was added, or when Read again was pressed.
  if (draft.status === "reading") return now - Date.parse(draft.updated_at ?? draft.created_at) < STUCK_MS ? "reading" : "failed";
  return draft.status === "failed" ? "failed" : "read";
}

/** What a draft that waits to be filled in says under its name. */
export const TO_FILL_LINE = "To fill in";
/** Its menu's way to read it after all, once reading has been switched on. */
export const READ_IT = "Read it";

/** What a draft waiting for its turn says under its name. */
export const WAITING_LINE = "Waiting its turn to be read";
/** And beneath that, once: why, and that nothing needs doing. */
export const WAITING_WHY = "That's all that can be read this hour. The rest are read by themselves while this page is open, or you can fill one in now.";
/** How often the page asks again for the drafts waiting their turn. */
export const WAITING_RETRY_MS = 5 * 60_000;

/**
 * The draft to ask about next, among those waiting their turn: the one that has waited longest.
 * One at a time: if it's still waiting after being asked, so would the others be.
 */
export function nextWaiting<T extends { id: string; status: string; created_at: string }>(drafts: readonly T[]): T | null {
  return [...drafts].filter((d) => d.status === "waiting").sort((a, b) => a.created_at.localeCompare(b.created_at))[0] ?? null;
}

/** The drop zone's words while reading is off: it still takes files, and says what happens to them. Null while it's on. */
export function dropZoneOff(readingOn: boolean, admin: boolean): { hint: string } | null {
  if (readingOn) return null;
  return {
    hint: `Photos or PDFs. Reading receipts is off, so each one waits here for you to fill in and save: none counts in job costing until it is. ${admin ? "Turn reading on in Settings → Company to have them filled in for you." : "An owner or admin can turn reading on in Settings → Company."}`,
  };
}

/** Said on a draft the server couldn't be asked to read because it's from before this feature. */
export const OLD_SERVER = "This server hasn't been updated to read receipts yet. Ones added after it's updated are read.";

/**
 * Why a draft that was just added couldn't be sent to be read, to keep on it. A server from before
 * this feature has no such address (404, though the draft is right there); anything else is said as
 * it came, or as no connection.
 */
export function unreadReason(error: unknown): string {
  if (error instanceof ApiError && (error.status === 404 || error.status === 405)) return OLD_SERVER;
  if (error instanceof ApiError && error.message) return error.message.slice(0, 500);
  return "It couldn't be sent to be read. Check your connection and use Read again.";
}
