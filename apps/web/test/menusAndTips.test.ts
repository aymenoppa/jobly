/**
 * Menus show what's there to choose and nothing left over (components/ui/menuEntries.ts), and the
 * tooltip layer lifts a title and puts back exactly what it found (components/ui/titles.ts).
 */
import { describe, expect, it } from "vitest";
import { hasActions, shownEntries, type MenuEntry, type ShownEntry } from "@/components/ui/menuEntries";
import { liftTitle, restoreTitle, tipAdds, titleText, type TitleHost } from "@/components/ui/titles";

const act = (label: string, more: Partial<Extract<MenuEntry, { onSelect: () => void }>> = {}): MenuEntry => ({ label, onSelect: () => undefined, ...more });
/** What a menu draws, as short words: "a:Open", "-", "group:Heading[...]", "sub:More[...]", "tick:Dark". */
const read = (shown: ShownEntry[]): string[] =>
  shown.map((s) =>
    s.kind === "separator" ? "-"
      : s.kind === "group" ? `group:${s.heading}[${read(s.items).join(",")}]`
        : s.kind === "submenu" ? `sub:${s.entry.label}[${read(s.items).join(",")}]`
          : s.kind === "tick" ? `tick:${s.entry.label}`
            : `a:${s.entry.label}`,
  );

describe("shownEntries", () => {
  it("leaves out hidden rows and the lines they leave at either end or doubled", () => {
    const items: MenuEntry[] = [
      { separator: true },
      act("Edit"),
      act("Copy", { hidden: true }),
      { separator: true },
      act("Archive", { hidden: true }),
      { separator: true },
      act("Delete", { danger: true }),
      { separator: true },
      act("Restore", { hidden: true }),
    ];
    expect(read(shownEntries(items))).toEqual(["a:Edit", "-", "a:Delete"]);
  });

  it("keeps a heading with the rows under it, and drops one with none", () => {
    const items: MenuEntry[] = [
      { heading: "Account" },
      act("Profile"),
      { separator: true },
      { heading: "Needs a key" },
      act("Refund", { hidden: true }),
      { separator: true },
      act("Sign out"),
    ];
    expect(read(shownEntries(items))).toEqual(["group:Account[a:Profile]", "-", "a:Sign out"]);
  });

  it("drops a submenu with nothing to choose in it, and tidies the inside of the rest", () => {
    const items: MenuEntry[] = [
      { label: "Move to", items: [{ heading: "Folders" }, act("Plans", { hidden: true })] },
      { label: "Appearance", items: [{ separator: true }, { label: "Light", checked: true, onCheckedChange: () => undefined }, { label: "Dark", checked: false, onCheckedChange: () => undefined }, { separator: true }] },
      { label: "Hidden", hidden: true, items: [act("Never")] },
    ];
    expect(read(shownEntries(items))).toEqual(["sub:Appearance[tick:Light,tick:Dark]"]);
  });

  it("says whether there's anything to choose", () => {
    expect(hasActions(shownEntries([]))).toBe(false);
    expect(hasActions(shownEntries([{ heading: "Nothing" }, { separator: true }, act("Gone", { hidden: true })]))).toBe(false);
    expect(hasActions(shownEntries([act("Open", { disabled: true, title: "Turned off" })]))).toBe(true);
    expect(hasActions(shownEntries([{ label: "Crew", checked: false, onCheckedChange: () => undefined }]))).toBe(true);
  });
});

/** Just enough of an element: its attributes and its words. */
function element(attrs: Record<string, string>, text = ""): TitleHost & { attrs: Map<string, string> } {
  const map = new Map(Object.entries(attrs));
  return {
    attrs: map,
    textContent: text,
    getAttribute: (name) => map.get(name) ?? null,
    setAttribute: (name, value) => void map.set(name, value),
    removeAttribute: (name) => void map.delete(name),
    hasAttribute: (name) => map.has(name),
  };
}
const TIP = "app-tooltip";

describe("lifting a title", () => {
  it("names an icon button by its title meanwhile, and puts everything back after", () => {
    const button = element({ title: "Delete", class: "btn" });
    const lifted = liftTitle(button, TIP)!;
    expect(Object.fromEntries(button.attrs)).toEqual({ title: "", "data-title": "Delete", "aria-label": "Delete", class: "btn" });
    expect(titleText(button)).toBe("Delete");
    restoreTitle(button, lifted, TIP);
    expect(Object.fromEntries(button.attrs)).toEqual({ title: "Delete", class: "btn" });
  });

  it("describes an element with a name of its own by the tooltip meanwhile, keeping what described it before", () => {
    const button = element({ title: "Why it's off", "aria-describedby": "hint" }, "Refund");
    const lifted = liftTitle(button, TIP)!;
    expect(button.getAttribute("aria-describedby")).toBe(`hint ${TIP}`);
    expect(button.hasAttribute("aria-label")).toBe(false);
    restoreTitle(button, lifted, TIP);
    expect(Object.fromEntries(button.attrs)).toEqual({ title: "Why it's off", "aria-describedby": "hint" });

    const labelled = element({ title: "More actions", "aria-label": "More actions" });
    const again = liftTitle(labelled, TIP)!;
    expect(labelled.getAttribute("aria-describedby")).toBe(TIP);
    restoreTitle(labelled, again, TIP);
    expect(Object.fromEntries(labelled.attrs)).toEqual({ title: "More actions", "aria-label": "More actions" });
  });

  it("leaves what the page changed meanwhile: a new title, or none", () => {
    const renamed = element({ title: "Old" });
    const one = liftTitle(renamed, TIP)!;
    renamed.setAttribute("title", "New");
    restoreTitle(renamed, one, TIP);
    expect(renamed.getAttribute("title")).toBe("New");
    expect(renamed.hasAttribute("data-title")).toBe(false);

    const cleared = element({ title: "Turned off because…" }, "Send");
    const two = liftTitle(cleared, TIP)!;
    cleared.removeAttribute("title");
    restoreTitle(cleared, two, TIP);
    expect(cleared.hasAttribute("title")).toBe(false);
    expect(cleared.hasAttribute("aria-describedby")).toBe(false);
  });

  it("has nothing to lift from an empty title", () => {
    const blank = element({ title: "" });
    expect(liftTitle(blank, TIP)).toBeNull();
    expect(Object.fromEntries(blank.attrs)).toEqual({ title: "" });
  });
});

describe("whether a tooltip adds anything", () => {
  it("not when the title only repeats the words shown, unless they're cut off", () => {
    const name = element({ title: "Jane  Doe" }, " Jane Doe ");
    expect(tipAdds(name, "Jane  Doe")).toBe(false);
    expect(tipAdds(name, "Jane  Doe", true)).toBe(true);
    expect(tipAdds(element({}, "Today"), "Nov 19, 2026")).toBe(true);
    expect(tipAdds(element({}), "   ")).toBe(false);
  });
});
