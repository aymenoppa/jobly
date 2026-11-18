import { describe, expect, it } from "vitest";
import { guideCodeEmail, guideInviteEmail, guideShareUrl, pictureName, readAddresses, sharedPictures } from "../src/guideShares";

// Sharing a guide by link: the link, the addresses typed into Add people, the emails, and which
// stored pictures a shared page may show. The routes are tested in apps/api/test/guideShares.test.ts.

const CO = "00000000-0000-4000-8000-0000000000c0";

describe("a shared guide's link", () => {
  it("is the app's address, then /g/ and its token", () => {
    expect(guideShareUrl("https://crm.peaklawn.example/", "0123456789abcdef0123456789abcdef")).toBe("https://crm.peaklawn.example/g/0123456789abcdef0123456789abcdef");
  });
});

describe("addresses typed into Add people", () => {
  it("are read however they're separated, each once in one spelling", () => {
    expect(readAddresses("Dana@Example.com, sam@example.com;lee@example.com\n dana@example.com ")).toEqual({ emails: ["dana@example.com", "sam@example.com", "lee@example.com"], bad: [] });
  });

  it("come out of what a mail program copies", () => {
    expect(readAddresses(`"Dana Reyes" <dana@example.com>, Sam Lee <sam@example.com>.`)).toEqual({ emails: ["dana@example.com", "sam@example.com"], bad: [] });
  });

  it("say which ones aren't whole addresses", () => {
    expect(readAddresses("dana@example, sam@example.com")).toEqual({ emails: ["sam@example.com"], bad: ["dana@example"] });
    expect(readAddresses("   ")).toEqual({ emails: [], bad: [] });
  });
});

describe("the emails", () => {
  it("tell someone a guide was shared with them, by whom, with its link and what opening it takes", () => {
    const mail = guideInviteEmail({ companyName: "Peak Lawn", title: "Caring for new sod", url: "https://crm.peaklawn.example/g/abc", by: "Pat Owner", access: "restricted" });
    expect(mail.subject).toBe("Peak Lawn shared a guide with you: Caring for new sod");
    expect(mail.text.split("\n\n")).toEqual([
      "Pat Owner at Peak Lawn shared a guide with you: Caring for new sod.",
      "https://crm.peaklawn.example/g/abc",
      "When you open it, you'll be asked for this email address and sent a code, so only the people it was shared with can read it.",
    ]);
  });

  it("say nothing of a code when anyone with the link can open it, and name the business when nobody is named", () => {
    const mail = guideInviteEmail({ companyName: "Peak Lawn", title: "Caring for new sod", url: "https://crm.peaklawn.example/g/abc", by: " ", access: "anyone" });
    expect(mail.text).toBe("Peak Lawn shared a guide with you: Caring for new sod.\n\nhttps://crm.peaklawn.example/g/abc");
  });

  it("keep a guide's title and a person's name to one line, so neither can add a paragraph or a button of its own", () => {
    const mail = guideInviteEmail({ companyName: "Peak Lawn", title: "Sod care\n\nhttps://evil.example/x\n\n", url: "https://crm.peaklawn.example/g/abc", by: "Pat\n\nhttps://evil.example/y", access: "anyone" });
    expect(mail.text.split("\n\n")).toEqual(["Pat https://evil.example/y at Peak Lawn shared a guide with you: Sod care https://evil.example/x.", "https://crm.peaklawn.example/g/abc"]);
    expect(mail.subject).toBe("Peak Lawn shared a guide with you: Sod care https://evil.example/x");
    const code = guideCodeEmail({ companyName: "Peak Lawn", title: "Sod care\n\n999999\n\n", code: "048213" });
    expect(code.text.split("\n\n").filter((p) => /^\d{6}$/.test(p))).toEqual(["048213"]);
  });

  it("send the code on a line of its own, so it's shown large", () => {
    const mail = guideCodeEmail({ companyName: "Peak Lawn", title: "Caring for new sod", code: "048213" });
    expect(mail.subject).toBe("Your code to open Caring for new sod");
    expect(mail.text.split("\n\n")).toContain("048213");
    expect(mail.text).toContain("It runs out in 15 minutes.");
  });
});

describe("the pictures a shared page may show", () => {
  const own = `${CO}/kb/7c0a0000-0000-4000-8000-000000000001.jpg`;
  const cover = `${CO}/kb/cover_1.jpg`;

  it("are the ones the guide names in its own company's kb/ folder, and its cover, each once", () => {
    const html = `<p>Set the cones.</p><img data-path="${own}" alt="Cones"><img data-path="${own}"><img src="https://example.com/x.png">`;
    expect(sharedPictures(CO, html, cover)).toEqual([cover, own]);
    expect(sharedPictures(CO, html)).toEqual([own]);
    expect(sharedPictures(CO, "", null)).toEqual([]);
  });

  it("are never another company's, outside kb/, in a folder under it, or a path that climbs out", () => {
    const paths = [
      "00000000-0000-4000-8000-0000000000c9/kb/a.jpg",
      `${CO}/receipts/a.jpg`,
      `${CO}/kb/deeper/a.jpg`,
      `${CO}/kb/../receipts/a.jpg`,
      `x${CO}/kb/a.jpg`,
      `${CO}/kb/a.jpg?x=1`,
      `${CO}/kb/a`,
    ];
    expect(sharedPictures(CO, paths.map((p) => `<img data-path="${p}">`).join(""))).toEqual([]);
    for (const path of paths) expect(sharedPictures(CO, "", path), path).toEqual([]);
  });

  it("are named on the page by the last part of their path", () => {
    expect(pictureName(own)).toBe("7c0a0000-0000-4000-8000-000000000001.jpg");
  });
});
