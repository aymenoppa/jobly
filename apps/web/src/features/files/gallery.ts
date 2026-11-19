/**
 * The photo gallery's sums and words (PhotoGallery.tsx), kept apart from React so they can be
 * tested: which photo to start on, what the counter says, which photos to load, and which clicks on
 * a thumbnail open the gallery rather than the link.
 */
import { t } from "@/lib/i18n";

export interface GalleryPhoto {
  id: string;
  url: string;
  alt: string;
}

/** The photo to show: the one asked for, kept to the photos there are (the first when there are none). */
export function clampIndex(index: number, count: number): number {
  if (count <= 0 || !Number.isFinite(index)) return 0;
  return Math.min(count - 1, Math.max(0, Math.trunc(index)));
}

/** "3 of 8": which photo is showing, counted from one. */
export const counterLabel = (index: number, count: number) => t("{number} of {count}", { number: clampIndex(index, count) + 1, count });

/** "Photo 3 of 8": a slide's name, for a screen reader. */
export const slideLabel = (index: number, count: number) => t("Photo {number} of {count}", { number: clampIndex(index, count) + 1, count });

/**
 * The photo showing and the one either side: loaded so a swipe lands on a picture rather than a
 * spinner, while the rest of a long visit's photos wait until they're nearly in view.
 */
export function nearby(index: number, count: number, reach = 1): number[] {
  const at = clampIndex(index, count);
  const near: number[] = [];
  for (let i = Math.max(0, at - reach); i <= Math.min(count - 1, at + reach); i++) near.push(i);
  return near;
}

/** The photos a gallery can show: only those with a link (one that didn't sign stays a thumbnail saying so). */
export function galleryOf<T extends { id: string; url: string | null }>(photos: readonly T[], alt: (photo: T) => string): GalleryPhoto[] {
  return photos.flatMap((p) => (p.url ? [{ id: p.id, url: p.url, alt: alt(p) }] : []));
}

/**
 * A click that opens the gallery: the main button with no key held. Ctrl, cmd or shift-click and
 * the middle button still open the photo in a new tab or window, as the link always has.
 */
export function isPlainClick(e: { button: number; metaKey: boolean; ctrlKey: boolean; shiftKey: boolean; altKey: boolean; defaultPrevented: boolean }): boolean {
  return e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey && !e.defaultPrevented;
}
