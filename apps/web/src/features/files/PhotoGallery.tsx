/**
 * Photos in the app, one at a time: a job's, a client's, a machine's and a crew's visit's. Tapping a
 * thumbnail opens the gallery at that photo; swipe or drag to the next, or use the arrows and the
 * arrow keys. Open full size is the photo on its own in a new tab, for zooming in and saving it.
 * The thumbnail stays a link, so opening it in a new tab works as it always has.
 */
import useEmblaCarousel from "embla-carousel-react";
import { useEffect, useState, type MouseEvent } from "react";
import { cx } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Icon } from "@/components/ui/Icon";
import { t } from "@/lib/i18n";
import { clampIndex, counterLabel, isPlainClick, nearby, slideLabel, type GalleryPhoto } from "./gallery";
import styles from "./PhotoGallery.module.css";

export type { GalleryPhoto } from "./gallery";
export { galleryOf } from "./gallery";

const stillMotion = () => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

export function PhotoGallery({ photos, start = 0, title = t("Photos"), onClose }: { photos: readonly GalleryPhoto[]; start?: number; title?: string; onClose: () => void }) {
  const count = photos.length;
  const first = clampIndex(start, count);
  // Embla's own easing for the arrows and keys, or straight there for someone who'd rather less
  // motion. A swipe still follows the finger and settles, as that's the person moving it.
  const [viewport, embla] = useEmblaCarousel({ startIndex: first, duration: stillMotion() ? 0 : 25 });
  const [selected, setSelected] = useState(first);
  // Loaded once near the photo showing, and kept, so going back doesn't load it again.
  const [loaded, setLoaded] = useState<ReadonlySet<number>>(() => new Set(nearby(first, count)));

  useEffect(() => {
    if (!embla) return;
    const select = () => {
      const at = embla.selectedScrollSnap();
      setSelected(at);
      setLoaded((had) => {
        const near = nearby(at, count).filter((i) => !had.has(i));
        return near.length ? new Set([...had, ...near]) : had;
      });
    };
    select();
    embla.on("select", select).on("reInit", select);
    return () => {
      embla.off("select", select).off("reInit", select);
    };
  }, [embla, count]);

  // The arrow keys, wherever focus is in the gallery: it opens with the dialog itself focused.
  useEffect(() => {
    if (!embla) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
      if (e.key === "ArrowLeft") embla.scrollPrev();
      else if (e.key === "ArrowRight") embla.scrollNext();
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [embla]);

  const current = photos[selected] ?? photos[first];
  if (!current) return null;
  return (
    <Dialog
      open
      onClose={onClose}
      title={title}
      description={<span className="tabular" aria-live="polite">{counterLabel(selected, count)}</span>}
      size="xl"
      className={styles.sheet}
    >
      <div className={styles.gallery}>
        <section className={styles.stage} aria-roledescription={t("carousel")} aria-label={title}>
          <div ref={viewport} className={styles.viewport}>
            <div className={styles.slides}>
              {photos.map((p, i) => (
                // Only the photo showing is read out; the others are off to the side.
                <div key={p.id} className={styles.slide} role="group" aria-roledescription={t("slide")} aria-label={slideLabel(i, count)} aria-hidden={i !== selected || undefined}>
                  {loaded.has(i) && (
                    <img
                      className={styles.photo}
                      src={p.url}
                      alt={p.alt}
                      draggable={false}
                      decoding="async"
                      onLoad={(e) => {
                        e.currentTarget.dataset.shown = "";
                      }}
                      onError={(e) => {
                        e.currentTarget.dataset.failed = "";
                      }}
                    />
                  )}
                  <span className={cx("spinner", styles.wait)} aria-hidden="true" />
                </div>
              ))}
            </div>
          </div>
          {/* Not disabled at the ends, which would drop the focus out of the gallery; it just does nothing there. */}
          {count > 1 && (
            <>
              <button type="button" className={cx(styles.arrow, styles.prev)} aria-label={t("Previous photo")} aria-disabled={selected === 0} onClick={() => embla?.scrollPrev()}>
                <Icon name="chevronLeft" size={22} bold />
              </button>
              <button type="button" className={cx(styles.arrow, styles.next)} aria-label={t("Next photo")} aria-disabled={selected === count - 1} onClick={() => embla?.scrollNext()}>
                <Icon name="chevronRight" size={22} bold />
              </button>
            </>
          )}
        </section>
        <div className={styles.foot}>
          <span className={styles.name} title={current.alt}>{current.alt}</span>
          <a className="btn btn-sm" href={current.url} target="_blank" rel="noopener noreferrer">
            <Icon name="external" size={14} />
            {t("Open full size")}
          </a>
        </div>
      </div>
    </Dialog>
  );
}

/**
 * The gallery for a page's thumbnails. Each thumbnail's link gets `onClick={gallery.opener(photos,
 * p.id)}`, where `photos` is what to swipe through (galleryOf), and `gallery.dialog` goes somewhere
 * outside the grid. Only a plain click opens it; any other click is the link's.
 */
export function usePhotoGallery() {
  const [shown, setShown] = useState<{ photos: GalleryPhoto[]; start: number; title?: string } | null>(null);
  return {
    opener: (photos: GalleryPhoto[], id: string, title?: string) => (e: MouseEvent<HTMLAnchorElement>) => {
      const start = photos.findIndex((p) => p.id === id);
      if (start < 0 || !isPlainClick(e)) return;
      e.preventDefault();
      // The photos as they were when it opened: a list refreshing behind it doesn't move it.
      setShown({ photos, start, title });
    },
    dialog: shown && <PhotoGallery photos={shown.photos} start={shown.start} title={shown.title} onClose={() => setShown(null)} />,
  };
}
