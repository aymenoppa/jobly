/**
 * Google's attribution on the measuring map, while it shows Google's tiles (Map Tiles API): the
 * Google Maps logo at the bottom left, and at the bottom right the data credit Google gives for
 * what's on screen, asked again each time the map settles somewhere new. Both are always in view
 * while Google's tiles are: neither folds away like the map's own credits do. With any other
 * imagery they're gone.
 *
 * The logo is Google's own artwork, unchanged and at its own size (assets/maps/README.md).
 */
import type { GoogleViewport } from "@jobly/core/imagery";
import type { IControl } from "maplibre-gl";
import logoUrl from "@/assets/maps/google-maps-logo.svg";
import { googleViewportCredit, imageryCredit } from "./imagery";

/** Shown until Google says what to show for what's on screen, and when it can't be asked. */
export const GOOGLE_CREDIT_FALLBACK = imageryCredit("google");
/** How long the map rests before Google is asked about the new view. */
const SETTLE_MS = 400;

export interface CreditWatch {
  /** Google's tiles are showing (true) or not: off, nothing is asked and what was asked is dropped. */
  show(on: boolean): void;
  /** The view changed: ask for its credit once the map has rested. */
  moved(): void;
  stop(): void;
}

/**
 * Keeps the credit in step with the view: the plain credit at once when Google's tiles come on,
 * then Google's own for what's on screen, asked once the map rests (so a drag asks once, not at
 * every frame) and not again for a view already asked about. An answer for a view the map has
 * left, or that arrives after Google's tiles went off, is dropped. No answer puts the plain credit
 * back, so a credit for somewhere else never stays up.
 */
export function watchCredit(options: {
  key: () => string | null | undefined;
  view: () => GoogleViewport | null;
  set: (text: string) => void;
  ask?: typeof googleViewportCredit;
  wait?: number;
}): CreditWatch {
  const ask = options.ask ?? googleViewportCredit;
  let on = false;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let asked = "";
  let turn = 0;
  const cancel = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
  };
  const run = () => {
    timer = undefined;
    const key = options.key();
    const view = on ? options.view() : null;
    if (!key || !view) return;
    const what = JSON.stringify(view);
    if (what === asked) return;
    asked = what;
    const mine = ++turn;
    void ask(key, view).then(
      (text) => {
        if (on && mine === turn) options.set(text ?? GOOGLE_CREDIT_FALLBACK);
        // Not answered: the same view is worth asking about again.
        if (text === null && mine === turn) asked = "";
      },
      () => {
        if (on && mine === turn) options.set(GOOGLE_CREDIT_FALLBACK);
        if (mine === turn) asked = "";
      },
    );
  };
  const later = (wait: number) => {
    cancel();
    timer = setTimeout(run, wait);
  };
  return {
    show(next) {
      if (next === on) return;
      on = next;
      cancel();
      turn++;
      asked = "";
      if (on) {
        options.set(GOOGLE_CREDIT_FALLBACK);
        later(0);
      }
    },
    moved() {
      if (on) later(options.wait ?? SETTLE_MS);
    },
    stop() {
      on = false;
      turn++;
      cancel();
    },
  };
}

/** The two things added to the map, and how the map tells them what's showing. */
export interface GoogleAttribution extends CreditWatch {
  /** Goes on the map's bottom left, before anything else there: Google's logo sits in the corner. */
  logo: IControl;
  /** Goes on the map's bottom right, before anything else there. */
  credit: IControl;
}

/** A map control that is just an element, kept out of the way of taps on the map. */
function control(element: HTMLElement): IControl {
  return {
    onAdd: () => element,
    onRemove: () => element.remove(),
  };
}

export function googleAttribution(options: { key: () => string | null | undefined; view: () => GoogleViewport | null }): GoogleAttribution {
  const logo = document.createElement("div");
  logo.className = "maplibregl-ctrl measure-google-logo";
  const image = document.createElement("img");
  image.src = logoUrl;
  // Google asks for this label, and for the logo at its own size and shape.
  image.alt = "Google Maps";
  image.width = 105;
  image.height = 22;
  image.draggable = false;
  logo.append(image);

  const credit = document.createElement("div");
  credit.className = "maplibregl-ctrl measure-google-credit";
  const visible = (on: boolean) => {
    logo.style.display = on ? "" : "none";
    credit.style.display = on ? "" : "none";
  };
  visible(false);

  const watch = watchCredit({ ...options, set: (text) => (credit.textContent = text) });
  return {
    logo: control(logo),
    credit: control(credit),
    show(on) {
      visible(on);
      watch.show(on);
    },
    moved: watch.moved,
    stop: watch.stop,
  };
}
