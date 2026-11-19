/**
 * What a menu (Menu.tsx, ContextMenu.tsx) is given, and what of it is shown. Kept apart from the
 * components so the tidying can be tested without a browser.
 */
import type { IconName } from "./Icon";

/** An action. `title` is shown on hover and focus, e.g. why it's turned off. */
export type MenuAction = { label: string; icon?: IconName; onSelect: () => void; danger?: boolean; disabled?: boolean; hidden?: boolean; title?: string };
/** A row that opens a menu of its own to the side. */
export type MenuSubmenu = { label: string; icon?: IconName; items: MenuEntry[]; disabled?: boolean; hidden?: boolean; title?: string };
/** A row with a tick that turns something on or off; the menu stays open to show the change. */
export type MenuTick = { label: string; checked: boolean; onCheckedChange: (checked: boolean) => void; disabled?: boolean; hidden?: boolean; title?: string };

export type MenuEntry =
  | MenuAction
  | MenuSubmenu
  | MenuTick
  | { separator: true; hidden?: boolean }
  | { heading: string; hidden?: boolean };

/** One thing a menu draws. A heading and the rows under it, up to the next line or heading, are a group. */
export type ShownEntry =
  | { kind: "action"; entry: MenuAction }
  | { kind: "tick"; entry: MenuTick }
  | { kind: "submenu"; entry: MenuSubmenu; items: ShownEntry[] }
  | { kind: "group"; heading: string; items: ShownEntry[] }
  | { kind: "separator" };

/**
 * The entries a menu shows: hidden ones left out, and with them whatever they leave behind with
 * nothing to do. A heading with no rows under it goes, as does a submenu with nothing in it, and a
 * line at either end or next to another line. Callers can hide rows freely without tidying up.
 */
export function shownEntries(items: readonly MenuEntry[]): ShownEntry[] {
  const out: ShownEntry[] = [];
  let group: { heading: string; items: ShownEntry[] } | null = null;
  const closeGroup = () => {
    if (group?.items.length) out.push({ kind: "group", heading: group.heading, items: group.items });
    group = null;
  };
  const add = (shown: ShownEntry) => (group ? group.items.push(shown) : out.push(shown));

  for (const item of items) {
    if (item.hidden) continue;
    if ("separator" in item) {
      closeGroup();
      if (out.length && out[out.length - 1].kind !== "separator") out.push({ kind: "separator" });
    } else if ("heading" in item) {
      closeGroup();
      group = { heading: item.heading, items: [] };
    } else if ("items" in item) {
      const inner = shownEntries(item.items);
      if (hasActions(inner)) add({ kind: "submenu", entry: item, items: inner });
    } else if ("checked" in item) {
      add({ kind: "tick", entry: item });
    } else {
      add({ kind: "action", entry: item });
    }
  }
  closeGroup();
  while (out.length && out[out.length - 1].kind === "separator") out.pop();
  return out;
}

/** Whether there's anything to choose (lines and groups are only there for the rows in them). */
export function hasActions(shown: readonly ShownEntry[]): boolean {
  return shown.some((s) => s.kind !== "separator");
}
