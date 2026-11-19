/**
 * Where something that floats over the page (a menu, a tooltip, a select's list, a preview card) has
 * to be put so it can be seen and used. An open modal dialog (Dialog.tsx) and a popover (Menu, the
 * bell, the toasts) sit in the browser's top layer, above everything else, and a modal dialog leaves
 * the rest of the page out of reach: something floating from inside one has to go inside it, or it
 * would open behind it. Otherwise it goes on the page itself.
 *
 * For Base UI's portals: <X.Portal container={layerFor(trigger)}>. Not being in one is undefined,
 * which Base UI takes as <body>: null would have it wait for a container instead, and never open.
 */
export function layerFor(el: Element | null | undefined): HTMLElement | undefined {
  return (el?.closest("dialog[open], [popover]") as HTMLElement | null) ?? undefined;
}
