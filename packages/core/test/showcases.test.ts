import { describe, expect, it } from "vitest";
import { publishCheck, showcaseCaption, showcaseOrder, showcaseProblem, unsharedQuestion } from "../src/showcases";
import { CLIENT_OPT_OUT } from "../src/social";

const JOB = "job-1";
const fact = (id: string, over: Partial<{ shareable: boolean; problem: string | null; job_id: string | null }> = {}) => ({ id, shareable: true, problem: null, job_id: JOB, ...over });

describe("publishing a showcase", () => {
  it("needs a title and one to twelve photos", () => {
    expect(showcaseProblem({ title: " ", description: "", photos: 2 })).toBe("Give the showcase a title.");
    expect(showcaseProblem({ title: "Driveway resealed", description: "", photos: 0 })).toBe("Pick at least one photo.");
    expect(showcaseProblem({ title: "Driveway resealed", description: "", photos: 13 })).toBe("Pick up to 12 photos.");
    expect(showcaseProblem({ title: "Driveway resealed", description: "x".repeat(2001), photos: 1 })).toMatch(/2,000 characters/);
    expect(showcaseProblem({ title: "Driveway resealed", description: "Before and after.", photos: 2 })).toBeNull();
  });

  it("never shows a client's photos when they asked that their property not be posted", () => {
    expect(publishCheck(JOB, ["a", "b"], [fact("a"), fact("b", { problem: "client_opt_out" })])).toEqual({ ok: false, reason: CLIENT_OPT_OUT });
  });

  it("shows only this job's JPEG and PNG photos", () => {
    expect(publishCheck(JOB, ["a"], [fact("a", { job_id: "other-job" })])).toMatchObject({ ok: false, reason: expect.stringMatching(/isn't on this job/) });
    expect(publishCheck(JOB, ["a"], [])).toMatchObject({ ok: false });
    expect(publishCheck(JOB, ["a"], [fact("a", { problem: "format" })])).toMatchObject({ ok: false, reason: expect.stringMatching(/JPEG and PNG/) });
  });

  it("counts the photos nobody marked OK to share, to ask about before they're shown", () => {
    expect(publishCheck(JOB, ["a", "b", "c"], [fact("a"), fact("b", { shareable: false }), fact("c", { shareable: false })])).toEqual({ ok: true, unshared: 2 });
    expect(publishCheck(JOB, ["a"], [fact("a")])).toEqual({ ok: true, unshared: 0 });
    expect(unsharedQuestion(2, 3)).toBe("2 of these photos aren't marked OK to share, so the client may not have agreed to their photos being shown.");
    expect(unsharedQuestion(1, 1)).toMatch(/^This photo isn't/);
    expect(unsharedQuestion(3, 3)).toMatch(/^These 3 photos aren't/);
  });
});

describe("a showcase's page and posts", () => {
  it("puts before photos first, then after, then the rest, each as picked", () => {
    const photos = [
      { id: 1, role: "after" as const, sort: 0 },
      { id: 2, role: "photo" as const, sort: 1 },
      { id: 3, role: "before" as const, sort: 2 },
      { id: 4, role: "after" as const, sort: 3 },
    ];
    expect(showcaseOrder(photos).map((p) => p.id)).toEqual([3, 1, 4, 2]);
  });

  it("captions a post with the title, the write-up and the link, within Instagram's 2,200 characters", () => {
    expect(showcaseCaption("Driveway resealed", "Cracks filled, two coats.", "https://jobly.example.com/s/abc")).toBe("Driveway resealed\n\nCracks filled, two coats.\n\nhttps://jobly.example.com/s/abc");
    const long = showcaseCaption("Title", "word ".repeat(1000), "https://jobly.example.com/s/abc");
    expect(long.length).toBeLessThanOrEqual(2200);
    expect(long.endsWith("https://jobly.example.com/s/abc")).toBe(true);
    expect(long).toContain("…");
  });
});
