/**
 * A right-click menu, on Base UI's ContextMenu (MIT), with the same entries as Menu. It's a quicker
 * way in, never the only one: whatever it offers is on the page too (a row opens with a click, its ⋯
 * menu has the rest), since not everyone knows to right-click, or can.
 *
 * The browser's own menu still comes up where it's what's wanted: over a text field, over words
 * picked to copy, and wherever there's nothing to offer.
 */
import { ContextMenu as Base } from "@base-ui/react/context-menu";
import { useRef, useState, type HTMLAttributes, type MouseEvent as ReactMouseEvent, type ReactElement, type ReactNode } from "react";
import { useNavigate } from "react-router-dom";
import { copyText } from "@/lib/clipboard";
import { t } from "@/lib/i18n";
import { layerFor } from "./layer";
import { MenuPopup } from "./Menu";
import { hasActions, shownEntries, type MenuEntry } from "./menuEntries";
import type { Selection } from "./Selection";

/** How long a touch counts as how a right-click came, where the event doesn't say. */
const TOUCH_MS = 1000;

export function ContextMenu({
  items,
  touch = true,
  render,
  children,
  style,
  onContextMenu,
  onPointerDown,
  onTouchStart,
  ...props
}: {
  /** The entries, or a way to get them for what was right-clicked (null for the browser's own). */
  items: MenuEntry[] | ((target: Element) => MenuEntry[] | null);
  /** Whether holding a finger down opens it too: not where that already does something (useHoldToPick). */
  touch?: boolean;
  /** The element it's on, e.g. <tbody />: a <div> otherwise. */
  render?: ReactElement;
  children: ReactNode;
} & Omit<HTMLAttributes<HTMLElement>, "children">) {
  // What was right-clicked, for its entries and the layer to open in.
  const [target, setTarget] = useState<Element | null>(null);
  // Where focus was before it opened, to go back to.
  const before = useRef<HTMLElement | null>(null);
  const lastPointer = useRef({ type: "", at: 0 });
  const entriesFor = (el: Element) => {
    const list = typeof items === "function" ? items(el) : items;
    return list ? shownEntries(list) : [];
  };

  const byTouch = (e: ReactMouseEvent) => {
    // Chrome says which pointer a contextmenu came from; elsewhere it's the last one pressed here.
    const type = (e.nativeEvent as Partial<PointerEvent>).pointerType;
    if (type) return type === "touch";
    return lastPointer.current.type === "touch" && Date.now() - lastPointer.current.at < TOUCH_MS;
  };
  /** Whether there's a menu for this spot: not over a text field, and only with something in it. */
  const offers = (el: Element) =>
    !el.closest('input:not([type="checkbox"]):not([type="radio"]), textarea, select, [contenteditable]:not([contenteditable="false"])') && hasActions(entriesFor(el));
  const wanted = (e: ReactMouseEvent) => {
    const el = e.target as Element;
    if (!touch && byTouch(e)) return false;
    const picked = window.getSelection();
    if (picked && !picked.isCollapsed && picked.containsNode(el, true)) return false;
    return offers(el);
  };
  const remember = (el: Element) => {
    const focused = document.activeElement;
    before.current = focused instanceof HTMLElement && focused !== document.body ? focused : null;
    setTarget(el);
  };

  return (
    <Base.Root>
      <Base.Trigger
        render={render}
        {...props}
        // Base UI stops a held finger's callout (copy, open in a new tab) so its menu can take the
        // hold; where it doesn't take it, the phone's stays.
        style={touch ? style : { WebkitTouchCallout: undefined, ...style }}
        onPointerDown={(e) => {
          lastPointer.current = { type: e.pointerType, at: Date.now() };
          onPointerDown?.(e);
        }}
        onTouchStart={(e) => {
          onTouchStart?.(e);
          // A held finger opens it from Base UI's own timer, with no contextmenu event on an
          // iPhone: what it's on is noted now.
          if (!touch || !offers(e.target as Element)) e.preventBaseUIHandler();
          else remember(e.target as Element);
        }}
        onContextMenu={(e) => {
          onContextMenu?.(e);
          if (e.isDefaultPrevented()) {
            e.preventBaseUIHandler();
            return;
          }
          if (!wanted(e)) {
            // The browser's menu, then: Base UI turns it off for the whole area unless the event
            // stops here.
            e.preventBaseUIHandler();
            e.stopPropagation();
            return;
          }
          remember(e.target as Element);
        }}
      >
        {children}
      </Base.Trigger>
      <MenuPopup
        layer={layerFor(target) ?? undefined}
        entries={target ? entriesFor(target) : []}
        // Back where focus was (Base UI would take it to the first thing in the area it covers),
        // unless what was chosen put it somewhere else, like a dialog's first field.
        finalFocus={() => {
          const now = document.activeElement;
          if (now && now !== document.body && !now.closest('[role="menu"]')) return false;
          return before.current?.isConnected ? before.current : false;
        }}
      />
    </Base.Root>
  );
}

/**
 * Right-click on a list's rows (Jobs, Quotes, Invoices, Clients): open it, here or in a new tab,
 * pick it where the row has a box (SelectCell), or copy its link. It's the list's <tbody>, taking its
 * props (useHoldToPick's among them), and each row says which it is with data-row={id}.
 *
 * A mouse's only: on a phone, holding a row already picks it.
 */
export function RowMenu({ href, selection, children, ...props }: { href: (id: string) => string; selection?: Selection; children: ReactNode } & Omit<HTMLAttributes<HTMLElement>, "children">) {
  const navigate = useNavigate();
  const entries = (target: Element): MenuEntry[] | null => {
    const row = target.closest<HTMLElement>("tr[data-row]");
    const id = row?.dataset.row;
    if (!row || !id) return null;
    const url = href(id);
    // A link in the row to somewhere else (the client's name) keeps the browser's own menu, so its
    // "Open in new tab" and "Copy link" are for where it goes, not for the row.
    const link = target.closest<HTMLAnchorElement>("a[href]");
    if (link && new URL(link.href, location.href).pathname !== new URL(url, location.href).pathname) return null;
    const picked = selection?.has(id) ?? false;
    return [
      { label: t("Open"), icon: "arrowRight", onSelect: () => navigate(url) },
      { label: t("Open in a new tab"), icon: "external", onSelect: () => window.open(url, "_blank", "noopener") },
      { label: picked ? t("Deselect") : t("Select"), icon: picked ? "x" : "check", hidden: !selection || !row.querySelector("[data-pick]"), onSelect: () => selection?.toggle(id) },
      { separator: true },
      { label: t("Copy link"), icon: "link", onSelect: () => void copyText(new URL(url, window.location.origin).href, t("Link copied")) },
    ];
  };
  return (
    <ContextMenu render={<tbody />} touch={false} items={entries} {...props}>
      {children}
    </ContextMenu>
  );
}
