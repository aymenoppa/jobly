/**
 * A dropdown menu, on Base UI's Menu (MIT). Arrow keys, Home and End, and typing the start of a
 * label move between items; a submenu opens to the side; it turns to stay on screen and follows its
 * button as the page scrolls; and it fades in and out (without the movement for less motion,
 * components.css). It isn't modal, like the popover it replaced: the page still scrolls, and a click
 * outside closes it and goes through.
 *
 * It opens in the layer its button is in (layer.ts): inside an open dialog or popover, where a menu
 * put on the page would sit behind it, out of reach.
 */
import { Menu as Base } from "@base-ui/react/menu";
import { useRef, useState, type ReactNode } from "react";
import { Icon } from "./Icon";
import { layerFor } from "./layer";
import { hasActions, shownEntries, type MenuEntry, type ShownEntry } from "./menuEntries";
import { t } from "@/lib/i18n";

export type { MenuEntry } from "./menuEntries";

export function Menu({
  items,
  label = t("More actions"),
  trigger,
  triggerClassName = "btn btn-icon",
  align = "end",
}: {
  items: MenuEntry[];
  label?: string;
  trigger?: ReactNode;
  triggerClassName?: string;
  align?: "start" | "end";
}) {
  const button = useRef<HTMLButtonElement>(null);
  // Which layer to open in is only known once the button is on the page, so it's found as it opens.
  const [layer, setLayer] = useState<HTMLElement>();
  const shown = shownEntries(items);
  if (!hasActions(shown)) return null;

  // Once it's closed, focus goes back to the button, unless what was chosen put it somewhere else
  // (a dialog's first field, a box to rename in), which Base UI leaves alone.
  return (
    <Base.Root modal={false} onOpenChange={(open) => open && setLayer(layerFor(button.current) ?? undefined)}>
      <Base.Trigger ref={button} className={triggerClassName} aria-label={label} title={trigger ? undefined : label}>
        {trigger ?? <Icon name="more" size={20} />}
      </Base.Trigger>
      <MenuPopup layer={layer} place={{ align, sideOffset: 6 }} entries={shown} />
    </Base.Root>
  );
}

/**
 * The popup of a Menu or ContextMenu (whose parts are Menu's) and its rows. `layer` is the dialog or
 * popover to open in, or none for the page. On the page the positioner's z-index is above the
 * sticky header and the tab bar (components.css); it's fixed, so a dialog's edges don't cut it off.
 */
export function MenuPopup({
  layer,
  place,
  entries,
  finalFocus,
}: {
  layer: HTMLElement | undefined;
  /** Against a button; a right-click's menu leaves it to Base UI, which puts it at the pointer. */
  place?: { align: "start" | "end"; sideOffset: number };
  entries: ShownEntry[];
  /** Where focus goes once it's closed (Base UI's default: back to the button). */
  finalFocus?: () => HTMLElement | false;
}) {
  return (
    <Base.Portal container={layer}>
      <Base.Positioner className="menu-positioner" positionMethod="fixed" collisionPadding={8} {...place}>
        <Base.Popup className="menu" finalFocus={finalFocus}>
          <MenuRows entries={entries} />
        </Base.Popup>
      </Base.Positioner>
    </Base.Portal>
  );
}

function MenuRows({ entries }: { entries: ShownEntry[] }) {
  return (
    <>
      {entries.map((shown, i) => {
        if (shown.kind === "separator") return <Base.Separator key={i} className="menu-sep" />;
        if (shown.kind === "group") {
          return (
            <Base.Group key={i}>
              <Base.GroupLabel className="menu-label">{shown.heading}</Base.GroupLabel>
              <MenuRows entries={shown.items} />
            </Base.Group>
          );
        }
        if (shown.kind === "tick") {
          const tick = shown.entry;
          return (
            <Base.CheckboxItem key={i} className="menu-item" checked={tick.checked} onCheckedChange={(checked) => tick.onCheckedChange(checked)} disabled={tick.disabled} title={tick.title}>
              <span className="menu-tick">
                <Base.CheckboxItemIndicator>
                  <Icon name="check" size={16} />
                </Base.CheckboxItemIndicator>
              </span>
              {tick.label}
            </Base.CheckboxItem>
          );
        }
        if (shown.kind === "submenu") {
          const sub = shown.entry;
          // Its popup goes inside this one's, so it's in the same layer. Lined up so its first row
          // is level with the row that opened it (the popup's padding and border).
          return (
            <Base.SubmenuRoot key={i}>
              <Base.SubmenuTrigger className="menu-item" disabled={sub.disabled} title={sub.title}>
                {sub.icon && <Icon name={sub.icon} size={16} />}
                {sub.label}
                <span className="menu-more"><Icon name="chevronRight" size={14} /></span>
              </Base.SubmenuTrigger>
              <Base.Portal>
                <Base.Positioner className="menu-positioner" positionMethod="fixed" collisionPadding={8} sideOffset={4} alignOffset={-5}>
                  <Base.Popup className="menu">
                    <MenuRows entries={shown.items} />
                  </Base.Popup>
                </Base.Positioner>
              </Base.Portal>
            </Base.SubmenuRoot>
          );
        }
        const action = shown.entry;
        return (
          <Base.Item key={i} className="menu-item" data-danger={action.danger || undefined} disabled={action.disabled} title={action.title} onClick={() => action.onSelect()}>
            {action.icon && <Icon name={action.icon} size={16} />}
            {action.label}
          </Base.Item>
        );
      })}
    </>
  );
}
