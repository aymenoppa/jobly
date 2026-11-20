/**
 * The app in Spanish (lib/i18n.tsx): sentences with links translated whole (<T>), dates, times and
 * money formatted es-US for whoever chose Spanish and en-US for everyone else, and the screens a
 * crew uses kept free of English typed outside t() (scripts/i18n.mjs COVERED; `node scripts/i18n.mjs
 * report` lists what's left anywhere).
 */
import { addCatalog, setLocale } from "@jobly/core/i18n";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { COVERED, listFiles, rawStrings, ROOT } from "../../../scripts/i18n.mjs";
import { formatDate, formatDateTime, formatDay, formatMoney, formatMoneyCents, formatNumber, formatTime, timeAgo, weekdayName } from "../src/lib/format";
import { T } from "../src/lib/i18n";

addCatalog("es", {
  "Test: Read the <link>terms</link> before {date}": "Test: Lee los <link>términos</link> antes del {date}",
});

afterEach(() => setLocale("en"));

const html = (node: Parameters<typeof renderToStaticMarkup>[0]) => renderToStaticMarkup(node).replace(/<!-- -->/g, "");

describe("<T>", () => {
  const sentence = () =>
    createElement(T, { text: "Test: Read the <link>terms</link> before {date}", link: (s: unknown) => createElement("a", { href: "/license" }, s as string), date: createElement("b", null, "Oct 15") });

  it("draws links and values inside the English sentence", () => {
    expect(html(sentence())).toBe('Test: Read the <a href="/license">terms</a> before <b>Oct 15</b>');
  });

  it("draws them inside the Spanish sentence, wherever Spanish puts them", () => {
    setLocale("es");
    expect(html(sentence())).toBe('Test: Lee los <a href="/license">términos</a> antes del <b>Oct 15</b>');
  });
});

describe("formatting", () => {
  const when = "2026-10-15T16:20:00Z";

  it("stays en-US for everyone who didn't choose Spanish", () => {
    expect(formatMoney(1234)).toBe("$1,234");
    expect(formatMoneyCents(1234.5)).toBe("$1,234.50");
    expect(formatDay("2026-10-15T12:00:00")).toBe("Thu, Oct 15");
    expect(formatDate("2026-10-15")).toBe("Oct 15, 2026");
    expect(formatTime(when, "America/Chicago").replace(/\s/g, " ")).toBe("11:20 AM");
    expect(formatDateTime(when, "America/Chicago").replace(/\s/g, " ")).toBe("Thu, Oct 15, 11:20 AM");
    expect(formatNumber(1234.5, 1)).toBe("1,234.5");
    expect(timeAgo(new Date())).toBe("just now");
    expect(weekdayName(4)).toBe("Thursday");
  });

  it("is es-US in Spanish: US money and numbers, Spanish days and times", () => {
    setLocale("es");
    expect(formatMoney(1234)).toBe("$1,234");
    expect(formatMoneyCents(1234.5)).toBe("$1,234.50");
    expect(formatDay("2026-10-15T12:00:00")).toBe("jue, 15 de oct");
    expect(formatDate("2026-10-15")).toBe("15 oct 2026");
    expect(formatTime(when, "America/Chicago").replace(/\s/g, " ")).toBe("11:20 a.m.");
    expect(formatNumber(1234.5, 1)).toBe("1,234.5");
    expect(weekdayName(4)).toBe("jueves");
    expect(timeAgo(new Date(Date.now() - 2 * 86_400_000))).toBe("anteayer");
  });
});

describe("the screens a crew uses", () => {
  it("have no English typed outside t()", () => {
    const left = listFiles(COVERED).flatMap((file) => rawStrings(file).map((s) => `${file}:${s.line} [${s.kind}] ${s.text}`));
    expect(left).toEqual([]);
  }, 60_000);
});

describe("the check for English typed outside t()", () => {
  /** What the check reports in a file with this in it. */
  const found = (code: string) => {
    const dir = mkdtempSync(join(tmpdir(), "jobly-i18n-"));
    try {
      writeFileSync(join(dir, "Screen.tsx"), code);
      return rawStrings(relative(ROOT, join(dir, "Screen.tsx"))).map((s) => s.text);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  };

  it("sees words kept in a variable, built in a template, picked by ?:, given as a fallback or returned by a helper", () => {
    const leaks = found(`
      export function Screen({ channel, v, crew, team, id, names }) {
        const placeholder = channel.kind === "announcement" ? \`Message \${channel.name}\` : \`Message #\${channel.name}\`;
        const when = \`\${v.scheduled_on ? day(v.scheduled_on) : "Not scheduled yet"}\${v.starts_at ? "" : v.scheduled_on ? " · Anytime" : ""}\`;
        let message;
        message = "Moved to unscheduled";
        const crewNote = \` · \${crew?.name ?? "no crew"}\`;
        const name = team.find((m) => m.user_id === id)?.full_name ?? "Team member";
        const other = memberName(team[0], "Team member");
        const pin = useMutation({ meta: { success: (_, on) => (on ? "Pinned to the top of the knowledge base" : "Unpinned") } });
        const typing = names.length === 1 ? \`\${names[0]} is typing…\` : "Several people are typing…";
        const note = \`\${when} at \${clock}\`;
        const label = () => "Nobody assigned";
        return <Cards empty={<NewGuideButton label="Write a guide" />} placeholder={placeholder} />;
      }
    `);
    for (const text of ["`Message ${channel.name}`", "`Message #${channel.name}`", "Not scheduled yet", " · Anytime", "Moved to unscheduled", "no crew", "Team member", "Pinned to the top of the knowledge base", "Unpinned", "`${names[0]} is typing…`", "Several people are typing…", "`${when} at ${clock}`", "Nobody assigned", "Write a guide"]) {
      expect(leaks, text).toContain(text);
    }
  });

  it("leaves names for the machine alone, and text that's already in t()", () => {
    expect(
      found(`
      import { api } from "@/lib/api";
      export function Screen({ v, status, tone }) {
        const rows = supabase().from("visits").select("id, title, crew:crews(name)").eq("status", "in_progress");
        const key = ["field", v.id, "Photos"];
        const cls = \`chip \${tone === "good" ? "chip-green" : "chip-blue"}\`;
        const kind = status === "Draft" ? "draft" : "sent";
        const path = \`/field/visits/\${v.id}\`;
        const header = { Authorization: \`Bearer \${token}\`, "Content-Type": "application/json" };
        const size = \`\${h}h \${m}m\`;
        const title = \`\${v.title} · Jobly\`;
        const said = on ? t("Pinned to the top of the knowledge base") : t("Unpinned");
        const constant = msg("Moved to unscheduled");
        if (event.key === "Enter" || event.key === "Escape") document.getElementById("photo-editor-words")?.focus();
        // i18n-ignore: said to the office
        const office = "You can still give them work";
        return <div className="row wrap" role="group" data-kind="Visit card" style={{ gridTemplateColumns: "1fr auto" }}>{t("Start visit")}</div>;
      }
    `),
    ).toEqual([]);
  });
});
