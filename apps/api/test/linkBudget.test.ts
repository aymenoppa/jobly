import { afterEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { LINK_BYTES_A_DAY, linkBytesADay, linkCanSend } from "../src/lib/linkBudget";

describe("a public link's daily budget", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("is 2 GB unless PUBLIC_LINK_GB_A_DAY says otherwise, and 0 turns it off", () => {
    expect(linkBytesADay({})).toBe(LINK_BYTES_A_DAY);
    expect(linkBytesADay({ PUBLIC_LINK_GB_A_DAY: "" })).toBe(LINK_BYTES_A_DAY);
    expect(linkBytesADay({ PUBLIC_LINK_GB_A_DAY: "10" })).toBe(10_000_000_000);
    expect(linkBytesADay({ PUBLIC_LINK_GB_A_DAY: "0.5" })).toBe(500_000_000);
    expect(linkBytesADay({ PUBLIC_LINK_GB_A_DAY: "0" })).toBeNull();
    // Something that isn't an amount keeps the default rather than taking the limit off.
    expect(linkBytesADay({ PUBLIC_LINK_GB_A_DAY: "lots" })).toBe(LINK_BYTES_A_DAY);
    expect(linkBytesADay({ PUBLIC_LINK_GB_A_DAY: "-3" })).toBe(LINK_BYTES_A_DAY);
  });

  it("counts nothing when it's off", async () => {
    const fetch = vi.fn();
    vi.stubGlobal("fetch", fetch);
    const env = { SUPABASE_URL: "http://db.test", SUPABASE_SECRET_KEY: "secret", PUBLIC_LINK_GB_A_DAY: "0" } as Env;
    expect(await linkCanSend(env, "showcase:abc", 5_000_000)).toBe(true);
    expect(fetch).not.toHaveBeenCalled();
  });

  it("asks the database with the set amount, in KB", async () => {
    const bodies: unknown[] = [];
    vi.stubGlobal("fetch", async (_input: RequestInfo | URL, init?: RequestInit) => {
      bodies.push(JSON.parse(String(init?.body)));
      return Response.json(true);
    });
    const env = { SUPABASE_URL: "http://db.test", SUPABASE_SECRET_KEY: "secret", PUBLIC_LINK_GB_A_DAY: "5" } as Env;
    expect(await linkCanSend(env, "guide:tok", 2_500)).toBe(true);
    expect(bodies[0]).toMatchObject({ p_key: "link-bytes:guide:tok", p_amount: 3, p_max: 5_000_000, p_window_seconds: 86_400 });
  });
});
