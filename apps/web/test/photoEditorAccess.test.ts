/**
 * The photo editor for someone who can't see it well (components/PhotoEditor.tsx): opening is a
 * status whose label is read, a photo that won't open is announced, and the example in its words
 * field, like every field's, is dark enough to read (WCAG 4.1.2, 4.1.3, 1.4.3).
 */
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { Spinner } from "../src/components/ui/Button";
import { contrastRatio } from "../src/features/documents/words";

const read = (path: string) => readFileSync(new URL(`../src/${path}`, import.meta.url), "utf8");
const editor = read("components/PhotoEditor.tsx");
const components = read("styles/components.css");
const tokens = read("styles/tokens.css");

describe("the photo editor", () => {
  it("says it's opening the photo: a status with its label, not a bare span whose label is never read", () => {
    expect(editor).toContain('<Spinner size={28} label={t("Opening the photo")} />');
    expect(editor).not.toContain('<span className="spinner" style={{ width: 28, height: 28 }} aria-label');
    expect(renderToStaticMarkup(createElement(Spinner, { size: 28, label: "Opening the photo" }))).toBe('<span class="spinner" style="width:28px;height:28px" role="status" aria-label="Opening the photo"></span>');
  });

  it("announces a photo that didn't open, with what can still be done", () => {
    const failed = editor.slice(editor.indexOf("{failed ? ("), editor.indexOf(") : !picture ? ("));
    expect(failed).toContain('<div className="stack-sm" role="alert"');
    expect(failed).toContain("<span>{failed}</span>");
    expect(failed).toContain('t("You can still add it as it is.")');
  });

  it("has an example in its words field that reads on white, whatever the theme", () => {
    // The field is white in the editor in both themes.
    expect(components).toContain(".photo-editor-bar .input { background: #fff; color: #111; }");
    const placeholder = /\.photo-editor-bar \.input::placeholder \{ color: (#[0-9a-f]{6}); \}/.exec(components)![1]!;
    expect(contrastRatio(placeholder, "#ffffff")).toBeGreaterThanOrEqual(4.5);
  });
});

describe("the example in an empty field, everywhere", () => {
  const require = createRequire(import.meta.url);
  const sand = readFileSync(require.resolve("@radix-ui/colors/sand-dark.css"), "utf8");
  const light = tokens.slice(tokens.indexOf(":root {"), tokens.indexOf(":root.dark {"));
  const dark = tokens.slice(tokens.indexOf(":root.dark {"));
  const value = (css: string, name: string) => new RegExp(`--${name}:\\s*([^;]+);`).exec(css)![1]!.trim();
  const darkHex = (name: string) => new RegExp(`--${/var\(--(sand-\d+)\)/.exec(value(dark, name))![1]!}:\\s*(#[0-9a-f]{6});`).exec(sand)![1]!;

  it("is 4.5:1 or better on a field, in the light theme and the dark", () => {
    const token = /\.input::placeholder, \.textarea::placeholder \{ color: var\(--([a-z0-9-]+)\); \}/.exec(components)![1]!;
    expect(token).toBe("text-3");
    expect(contrastRatio(value(light, token), value(light, "surface"))).toBeGreaterThanOrEqual(4.5);
    expect(contrastRatio(darkHex(token), darkHex("surface"))).toBeGreaterThanOrEqual(4.5);
    // What it was: 3.0:1 in the light theme.
    expect(contrastRatio(value(light, "text-4"), value(light, "surface"))).toBeLessThan(3.1);
  });
});
