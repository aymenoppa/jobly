/**
 * Settings → Hosting's parts about the bill (features/settings/HostingSettings.tsx): owners on a
 * paid Railway plan are asked to set Railway's own hard usage limit, the one thing that stops the
 * bill, until they say they have; the bucket tip leads to Files storage on the same page.
 */
import type { HostingOverview } from "@jobly/core/hosting";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createElement, type ReactElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { MemoryRouter } from "react-router-dom";
import { describe, expect, it, vi } from "vitest";
import { SpendingLimit, suggestedLimit, usageLimitSetAt, Warning } from "../src/features/settings/HostingSettings";

const session = vi.hoisted(() => ({ current: null as unknown }));
vi.mock("../src/lib/session", () => ({
  useSession: () => session.current,
  hasRole: (s: { role: string }, ...roles: string[]) => s.role === "owner" || roles.includes(s.role),
  can: (s: { role: string; permissions: string[] }, p: string) => s.role === "owner" || s.permissions.includes(p),
  isSub: (s: { role: string }) => s.role === "subcontractor",
}));

const as = (role: string, settings: Record<string, unknown> = {}) => {
  session.current = { role, permissions: ["settings"], userId: "u-me", company: { id: "co", name: "Green Acres", settings }, config: { platform: "railway" }, refresh: async () => undefined };
};

const OVERVIEW: HostingOverview = {
  projectName: "Jobly",
  plan: "hobby",
  period: { start: "2026-11-01T00:00:00.000Z", end: "2026-12-01T00:00:00.000Z" },
  project: { cost: 3.1, perDay: 0.2, forecast: 7.4, services: [] },
  sent: { soFar: 1.2, perDay: 0.1, usualPerDay: 0.1, forecast: 2.5 },
  trial: null,
  disks: [],
  week: [],
  warnings: [],
  missing: [],
  links: { usage: "https://railway.com/workspace/usage", billing: "b", upgrade: "u", plans: "p", project: "https://railway.com/project/proj-1" },
  checkedAt: "2026-11-18T12:00:00.000Z",
};

const text = (html: string) => html.replace(/<[^>]+>/g, " ").replace(/&#x27;/g, "'").replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/\s+/g, " ");
function render(element: ReactElement) {
  const client = new QueryClient();
  return renderToStaticMarkup(createElement(QueryClientProvider, { client }, createElement(MemoryRouter, null, element)));
}

describe("Railway's spending limit", () => {
  it("asks owners on a paid plan to set one in Railway, with where and how much, until they say they have", () => {
    as("owner");
    const html = render(createElement(SpendingLimit, { o: OVERVIEW }));
    const page = text(html);
    expect(page).toContain("Set a spending limit in Railway");
    expect(page).toContain("only Railway can stop the bill");
    expect(page).toContain("Jobly can't set it for you, since it never sees your Railway billing.");
    expect(page).toContain("like $15: Jobly stops too when it's reached. Railway's lowest is $10.");
    expect(html).toContain('href="https://railway.com/workspace/usage"');
    expect(page).toContain("I've set it");

    as("owner", { railway_usage_limit: { set_at: "2026-11-18T12:00:00.000Z", set_by: "u-me" } });
    expect(render(createElement(SpendingLimit, { o: OVERVIEW }))).toBe("");
  });

  it("isn't shown to admins, or on the trial or Free, where there's no bill past the credit", () => {
    as("admin");
    expect(render(createElement(SpendingLimit, { o: OVERVIEW }))).toBe("");
    as("owner");
    for (const plan of ["trial", "free"] as const) expect(render(createElement(SpendingLimit, { o: { ...OVERVIEW, plan } })), plan).toBe("");
  });

  it("suggests about twice a normal month, rounded up to $5, and never under Railway's $10", () => {
    expect(suggestedLimit({ plan: "hobby", project: { cost: 1, perDay: 0.1, forecast: 3, services: [] } })).toBe(10);
    expect(suggestedLimit(OVERVIEW)).toBe(15);
    expect(suggestedLimit({ plan: "pro", project: null })).toBe(40);
    expect(usageLimitSetAt({})).toBeNull();
    expect(usageLimitSetAt({ railway_usage_limit: { set_at: "2026-11-18T12:00:00.000Z" } })).toBe("2026-11-18T12:00:00.000Z");
  });
});

describe("the bucket tip", () => {
  it("is a tip, not a warning, and leads to Files storage on the same page", () => {
    as("owner");
    const html = render(
      createElement(Warning, {
        warning: { key: "bucket", level: "tip", title: "Photos and files would cost a tenth as much in a Railway bucket", body: "They take 2.6 GB…", action: "files" },
        links: OVERVIEW.links,
      }),
    );
    expect(html).toContain("callout-info");
    expect(html).not.toContain('role="alert"');
    expect(text(html)).toContain("Go to Files storage");
  });
});
