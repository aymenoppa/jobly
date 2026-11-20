/**
 * The pages a business's clients open (the Client Hub, a booking form, an unsubscribe link, a
 * referral page, a job showcase, a guide shared by link) are treated as theirs everywhere: light theme and English
 * whatever the device last ran Jobly in (so `lang` is right for a screen reader: WCAG 3.1.1), no
 * "Install Jobly", and left alone by the crew's service worker. Each of those is its own list of
 * paths, in a file that can't import the others, so this holds every list to the routes.
 */
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const read = (path: string) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

/** The first part of each client-facing route's path, from the router itself. */
function clientRoutes(): string[] {
  const routes = read("src/routes.tsx");
  const block = routes.slice(routes.indexOf("// Client-facing pages work without an account."), routes.indexOf("// A subcontractor's link"));
  return [...block.matchAll(/\{ path: "([a-z]+)\//g)].map((m) => m[1]!);
}

/** Every regular expression in a file that lists the clients' pages, as the file wrote it. */
function lists(path: string): RegExp[] {
  return [...read(path).matchAll(/\/(\^\\\/\((?:[^/\\]|\\.)*\bhub\b(?:[^/\\]|\\.)*(?:\\\/|\(\\\/\|\$\)))\//g)].map((m) => new RegExp(m[1]!));
}

const FILES: Array<[path: string, lists: number, what: string]> = [
  ["src/lib/theme.ts", 1, "the light theme"],
  ["src/lib/i18n.tsx", 1, "English, and lang=\"en\""],
  ["src/lib/install.ts", 1, "no install prompt"],
  ["index.html", 2, "the theme and the language before the app loads"],
  ["public/sw.js", 2, "left alone by the service worker"],
];

describe("the pages clients open", () => {
  const routes = clientRoutes();

  it("are the hub, booking forms, unsubscribe links, referral pages, showcases and shared guides", () => {
    expect(routes).toEqual(["hub", "book", "u", "refer", "s", "g"]);
  });

  for (const [path, count, what] of FILES) {
    it(`are all listed in ${path} (${what})`, () => {
      const found = lists(path);
      expect(found, path).toHaveLength(count);
      for (const list of found) {
        for (const route of routes) expect(list.test(`/${route}/0123456789abcdef`), `${path}: /${route}/…`).toBe(true);
        // The crew's own screens that start with the same letters aren't clients' pages.
        for (const app of ["/schedule", "/settings", "/subs/1099", "/field", "/timesheets", "/users", "/"]) expect(list.test(app), `${path}: ${app}`).toBe(false);
      }
    });
  }

  it("so a showcase opened on a phone set to dark, or to Español, is still light and still says it's in English", () => {
    for (const [path] of FILES) for (const list of lists(path)) expect(list.test("/s/0123456789abcdef0123456789abcdef"), path).toBe(true);
    // A guide shared by link is read by people outside the team, the same way.
    for (const [path] of FILES) for (const list of lists(path)) expect(list.test("/g/0123456789abcdef0123456789abcdef"), path).toBe(true);
    // The two checks index.html makes before the app loads.
    const html = read("index.html");
    expect(html).toContain('if (!/^\\/(hub|book|u|refer|s|g)\\//.test(location.pathname) && (theme === "dark"');
    expect(html).toContain('localStorage.getItem("jobly.locale") === "es" && !/^\\/(hub|book|u|refer|s|g)\\//.test(location.pathname)) document.documentElement.lang = "es";');
  });
});
