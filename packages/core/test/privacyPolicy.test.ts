/**
 * The business's privacy policy link (privacyPolicy.ts): what's saved is shown only when it's a
 * web address, and Settings → Company tidies what was typed.
 */
import { describe, expect, it } from "vitest";
import { PRIVACY_LINK_LABEL, PRIVACY_URL_MAX, privacyUrl, privacyUrlTyped } from "../src/privacyPolicy";

describe("the privacy policy link a company saved", () => {
  it("is its web address", () => {
    expect(privacyUrl({ privacy_url: "https://acme.example/privacy" })).toBe("https://acme.example/privacy");
    expect(privacyUrl({ privacy_url: "  http://acme.example/legal/privacy.html#top " })).toBe("http://acme.example/legal/privacy.html#top");
    expect(PRIVACY_LINK_LABEL).toBe("Privacy policy");
  });

  it("is nothing when none is saved, or what's saved couldn't be linked to safely", () => {
    for (const settings of [null, undefined, {}, { privacy_url: null }, { privacy_url: "" }, { privacy_url: 7 }, { privacy_url: ["https://acme.example"] }]) expect(privacyUrl(settings as never)).toBeNull();
    for (const saved of ["javascript:alert(1)", "data:text/html,hi", "mailto:privacy@acme.example", "ftp://acme.example/privacy", "acme.example/privacy", "https://localhost/privacy", "https://acme.example/a b", `https://acme.example/${"a".repeat(PRIVACY_URL_MAX)}`]) {
      expect(privacyUrl({ privacy_url: saved }), saved).toBeNull();
    }
  });
});

describe("what's typed in Settings → Company", () => {
  it("is saved as a web address, with https:// put in front of a bare one", () => {
    expect(privacyUrlTyped("https://acme.example/privacy")).toBe("https://acme.example/privacy");
    expect(privacyUrlTyped(" acme.example/privacy ")).toBe("https://acme.example/privacy");
    expect(privacyUrlTyped("www.acme.example")).toBe("https://www.acme.example/");
  });

  it("clears the link when the box is emptied, and refuses what isn't a web address", () => {
    expect(privacyUrlTyped("")).toBeNull();
    expect(privacyUrlTyped("   ")).toBeNull();
    for (const typed of ["our privacy policy", "javascript:alert(1)", "mailto:privacy@acme.example", "privacy"]) expect(privacyUrlTyped(typed), typed).toBe("invalid");
  });
});
