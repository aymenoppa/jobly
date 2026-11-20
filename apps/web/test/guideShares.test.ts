/** What the Share dialog says after people are added to a guide (features/kb/shareWords.ts). */
import { describe, expect, it } from "vitest";
import { addedNote } from "../src/features/kb/shareWords";

describe("after adding people to a guide", () => {
  it("says who was added and that they got the link", () => {
    expect(addedNote({ added: ["dana@example.com"], emailed: ["dana@example.com"], problem: null }, 1)).toEqual({ ok: true, text: "Added dana@example.com and emailed them the link." });
    expect(addedNote({ added: ["a@x.co", "b@x.co"], emailed: ["a@x.co", "b@x.co"], problem: null }, 2)).toEqual({ ok: true, text: "Added 2 people and emailed each of them the link." });
  });

  it("says why when they were added but not emailed", () => {
    expect(addedNote({ added: ["dana@example.com"], emailed: [], problem: "It's a draft, so nobody was emailed. Publish it, then email them the link." }, 1)).toEqual({
      ok: false,
      text: "Added dana@example.com. It's a draft, so nobody was emailed. Publish it, then email them the link.",
    });
    expect(addedNote({ added: ["a@x.co", "b@x.co", "c@x.co"], emailed: ["a@x.co"], problem: "The mailbox's password was turned down." }, 3)).toEqual({
      ok: false,
      text: "Added 3 people, and emailed 1 of them the link. The mailbox's password was turned down.",
    });
    expect(addedNote({ added: ["dana@example.com"], emailed: [], problem: null }, 1).text).toBe("Added dana@example.com. They weren't emailed the link.");
  });

  it("says so when everyone typed was on the list already", () => {
    expect(addedNote({ added: [], emailed: [], problem: null }, 1)).toEqual({ ok: true, text: "They're already on the list." });
    expect(addedNote({ added: [], emailed: [], problem: null }, 3)).toEqual({ ok: true, text: "They're all on the list already." });
  });
});
