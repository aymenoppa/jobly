/**
 * Lifting an element's title while the pointer is on it, so the browser's own tooltip doesn't show
 * as well as the app's (Tooltips.tsx), and putting it back. Kept apart so it can be tested without a
 * browser: it only needs an element's attributes and text.
 *
 * The title moves to data-title and an empty one stands in: the browser shows nothing for an empty
 * title, and doesn't look further up the page for another. Assistive technology loses nothing:
 * where the title was the element's only name (an icon button with no aria-label), aria-label holds
 * it meanwhile; where the element has a name of its own and the title was its description,
 * aria-describedby points at the tooltip, which says the same.
 */

/** The parts of an element used here (any HTMLElement). */
export interface TitleHost {
  getAttribute(name: string): string | null;
  setAttribute(name: string, value: string): void;
  removeAttribute(name: string): void;
  hasAttribute(name: string): boolean;
  readonly textContent: string | null;
}

/** What lifting a title changed, so exactly that is undone. */
export interface LiftedTitle {
  text: string;
  /** The title went into aria-label, as the element's name. */
  label: boolean;
  /** aria-describedby as it was, when the tooltip was added to it. */
  describedBy: string | null;
}

/** Words as they read: any run of spaces and line breaks is one space. */
const plain = (text: string | null | undefined) => (text ?? "").replace(/\s+/g, " ").trim();

/** The title an element shows, lifted or not. */
export function titleText(el: TitleHost): string {
  return el.getAttribute("title") || el.getAttribute("data-title") || "";
}

/**
 * Whether a tooltip adds anything: not where the title only repeats the words already on the
 * element, unless they're cut off (a long name in a narrow column, with the whole of it as its title).
 */
export function tipAdds(el: TitleHost, title: string, cutOff = false): boolean {
  const text = plain(title);
  return Boolean(text) && (cutOff || text !== plain(el.textContent));
}

/** Lifts the title (see above). `tooltipId` is the tooltip's element, for aria-describedby. */
export function liftTitle(el: TitleHost, tooltipId: string): LiftedTitle | null {
  const text = el.getAttribute("title");
  if (!text) return null;
  const named = el.hasAttribute("aria-label") || el.hasAttribute("aria-labelledby") || Boolean(plain(el.textContent));
  el.setAttribute("data-title", text);
  el.setAttribute("title", "");
  if (!named) {
    el.setAttribute("aria-label", text);
    return { text, label: true, describedBy: null };
  }
  const describedBy = el.getAttribute("aria-describedby");
  el.setAttribute("aria-describedby", describedBy ? `${describedBy} ${tooltipId}` : tooltipId);
  return { text, label: false, describedBy };
}

/**
 * Puts a lifted title back. Whatever the page did to the title meanwhile (React gave it a new one,
 * or took it away) stands: only the empty stand-in is replaced. The same goes for the aria- parts.
 */
export function restoreTitle(el: TitleHost, lifted: LiftedTitle, tooltipId: string) {
  if (el.getAttribute("title") === "") el.setAttribute("title", lifted.text);
  el.removeAttribute("data-title");
  if (lifted.label) {
    if (el.getAttribute("aria-label") === lifted.text) el.removeAttribute("aria-label");
    return;
  }
  const now = el.getAttribute("aria-describedby");
  if (now === (lifted.describedBy ? `${lifted.describedBy} ${tooltipId}` : tooltipId)) {
    if (lifted.describedBy) el.setAttribute("aria-describedby", lifted.describedBy);
    else el.removeAttribute("aria-describedby");
  }
}
