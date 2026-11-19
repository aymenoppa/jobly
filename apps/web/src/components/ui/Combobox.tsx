/**
 * Type-to-search pickers, on Base UI's Combobox (MIT): the client picker (features/clients/ClientForm),
 * "Add from price list" on a quote's lines and the estimate's price-list search. The parts are Base
 * UI's own (Combobox.Root, .Input, .List, .Item…); ComboboxPopup is the floating list, drawn like a
 * Select's and put where it can be seen. Not for what every page loads, like Select.
 */
import { Combobox } from "@base-ui/react/combobox";
import { useCallback, useState, type ReactNode } from "react";
import { layerFor } from "./layer";
import "./pickers.css";

export { Combobox };

/**
 * Where a picker's list goes, worked out as it opens: inside the dialog or popover its box is in
 * (a modal dialog leaves the rest of the page out of reach), or on the page. Call `place` with the
 * box when the list opens.
 */
export function usePickerLayer(): [HTMLElement | undefined, (anchor: Element | null) => void] {
  const [layer, setLayer] = useState<HTMLElement | undefined>(undefined);
  const place = useCallback((anchor: Element | null) => setLayer(layerFor(anchor)), []);
  return [layer, place];
}

/**
 * A picker's floating list, under its box (above when there's no room below). `container` is where
 * it goes (usePickerLayer, or an element of the screen's own so its styles reach the list);
 * `className` adds to .picker-popup: picker-popup-fit for as wide as the box, picker-popup-search for
 * a search above the results.
 */
export function ComboboxPopup({ container, className, label, children }: { container: HTMLElement | null | undefined; className?: string; label?: string; children: ReactNode }) {
  return (
    // Base UI waits while a container is null, and uses <body> when there's none.
    <Combobox.Portal container={container ?? undefined}>
      <Combobox.Positioner className="picker-positioner" side="bottom" align="start" sideOffset={6} positionMethod="fixed" collisionPadding={8}>
        <Combobox.Popup className={className ? `picker-popup ${className}` : "picker-popup"} aria-label={label}>
          {children}
        </Combobox.Popup>
      </Combobox.Positioner>
    </Combobox.Portal>
  );
}
