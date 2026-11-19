/**
 * Springy motion for what a finger lets go of (a sheet pulled down and dropped short, a toast swiped
 * and let back) and for toasts arriving. Motion's small animate() runs it on the browser's own Web
 * Animations, with the spring worked out ahead of time as an easing curve, so it costs a few
 * kilobytes and nothing per frame. Nothing moves when the person prefers less motion.
 */
import { spring } from "motion";
import { animate } from "motion/mini";

const lessMotion = () => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Settles quickly with a small overshoot: lively without wobbling. */
const SETTLE = { type: spring, bounce: 0.22, visualDuration: 0.34 } as const;

/**
 * Motion leaves an animation's last frame on the element's own style when it ends. The stylesheet
 * says where things rest (a sheet's pull, a toast's place in its stack), so that's taken off again.
 */
function settle(el: HTMLElement, controls: { finished: Promise<unknown> }, properties: string[]): Promise<void> {
  const clear = () => properties.forEach((p) => el.style.removeProperty(p));
  return controls.finished.then(clear, clear);
}

/** Moves `el` from where the finger left it back to where its stylesheet puts it. */
export function springBack(el: HTMLElement, from: string): Promise<void> {
  if (lessMotion() || typeof el.animate !== "function") return Promise.resolve();
  return settle(el, animate(el, { transform: [from, "none"] }, SETTLE), ["transform"]);
}

/** Brings `el` in from `from` (a transform), fading up as it comes; with less motion it only fades. */
export function springIn(el: HTMLElement, from: string): void {
  if (typeof el.animate !== "function") return;
  if (lessMotion()) {
    el.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
    return;
  }
  void settle(el, animate(el, { opacity: [0, 1], transform: [from, "none"] }, { ...SETTLE, bounce: 0.3 }), ["opacity", "transform"]);
}
