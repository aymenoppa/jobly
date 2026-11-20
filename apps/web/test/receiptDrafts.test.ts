/**
 * Receipts dropped in several at once (jobs/receiptDraftWords.ts): with reading off they wait to be
 * filled in and are never called failures, the drop zone says reading is off, and one that couldn't
 * be sent to be read says why instead of sitting at "Reading…".
 */
import { describe, expect, it } from "vitest";
import { draftState, dropZoneOff, nextWaiting, OLD_SERVER, STUCK_MS, TO_FILL_LINE, unreadReason, WAITING_LINE, WAITING_RETRY_MS, WAITING_WHY } from "@/features/jobs/receiptDraftWords";
import { ApiError } from "@/lib/errors";

const at = "2026-11-14T15:00:00.000Z";
const now = Date.parse(at);

describe("a receipt waiting in the list", () => {
  it("is to fill in, not a failure, when reading is off", () => {
    expect(draftState({ status: "to_fill", created_at: at }, now)).toBe("to_fill");
    // However long it has waited.
    expect(draftState({ status: "to_fill", created_at: "2026-01-01T00:00:00Z" }, now)).toBe("to_fill");
    expect(TO_FILL_LINE).toBe("To fill in");
  });

  it("is being read for a few minutes, and after that was cut off: it can be read again", () => {
    expect(draftState({ status: "reading", created_at: at }, now + STUCK_MS - 1)).toBe("reading");
    expect(draftState({ status: "reading", created_at: at }, now + STUCK_MS)).toBe("failed");
    // Read again counts from when it was pressed, not from when the file was added.
    expect(draftState({ status: "reading", created_at: "2026-11-01T00:00:00Z", updated_at: at }, now + 1000)).toBe("reading");
    expect(draftState({ status: "read", created_at: at }, now)).toBe("read");
    expect(draftState({ status: "failed", created_at: at }, now)).toBe("failed");
  });
});

describe("a stack larger than the hour's allowance", () => {
  const draft = (id: string, status: string, created_at: string) => ({ id, status, created_at });

  it("waits its turn: not read yet, not failed, and it says nothing needs doing", () => {
    expect(draftState({ status: "waiting", created_at: "2026-01-01T00:00:00Z" }, now)).toBe("waiting");
    expect(WAITING_LINE).toBe("Waiting its turn to be read");
    expect(WAITING_WHY).toBe("That's all that can be read this hour. The rest are read by themselves while this page is open, or you can fill one in now.");
  });

  it("carries on with the one that has waited longest, a few minutes apart", () => {
    const drafts = [draft("c", "waiting", "2026-11-14T10:02:00Z"), draft("a", "read", "2026-11-14T10:00:00Z"), draft("b", "waiting", "2026-11-14T10:01:00Z"), draft("d", "failed", "2026-11-14T09:00:00Z")];
    expect(nextWaiting(drafts)?.id).toBe("b");
    expect(nextWaiting(drafts.filter((d) => d.id !== "b"))?.id).toBe("c");
    expect(nextWaiting(drafts.filter((d) => d.status !== "waiting"))).toBeNull();
    expect(WAITING_RETRY_MS).toBe(5 * 60_000);
  });
});

describe("the drop zone", () => {
  it("says reading is off and what happens to what's dropped, and who can turn it on", () => {
    expect(dropZoneOff(true, true)).toBeNull();
    expect(dropZoneOff(false, true)!.hint).toBe(
      "Photos or PDFs. Reading receipts is off, so each one waits here for you to fill in and save: none counts in job costing until it is. Turn reading on in Settings → Company to have them filled in for you.",
    );
    expect(dropZoneOff(false, false)!.hint).toContain("An owner or admin can turn reading on in Settings → Company.");
  });
});

describe("a receipt that couldn't be sent to be read", () => {
  it("says the server is from before reading, when it has no such address", () => {
    expect(unreadReason(new ApiError("Not found", 404))).toBe(OLD_SERVER);
    expect(unreadReason(new ApiError("Method not allowed", 405))).toBe(OLD_SERVER);
    expect(OLD_SERVER).toBe("This server hasn't been updated to read receipts yet. Ones added after it's updated are read.");
  });

  it("says what the server said otherwise, or that it couldn't be sent", () => {
    expect(unreadReason(new ApiError("You don't have permission to do that. Ask an admin if you need it.", 403))).toBe("You don't have permission to do that. Ask an admin if you need it.");
    expect(unreadReason(new TypeError("Failed to fetch"))).toBe("It couldn't be sent to be read. Check your connection and use Read again.");
  });
});
