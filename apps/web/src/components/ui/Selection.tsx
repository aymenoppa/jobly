/**
 * Picking rows on a list page to act on them at once: a box on each row, one in the heading for
 * every row on the page, and a bar above the list with how many are picked and what can be done.
 * The logic, and writing them in chunks, is lib/bulk.ts.
 */
import type { QueryKey } from "@tanstack/react-query";
import { useEffect, useRef, useState, type MouseEvent as ReactMouseEvent, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { inChunks, mergeResults, pageState, pickedOnPage, reportBulk, toggleAll, toggleOne, type BulkResult, type BulkWords } from "@/lib/bulk";
import { queryClient } from "@/lib/queryClient";
import type { ToastTone } from "@/lib/toast";
import { undoable } from "@/lib/undo";
import { Button, cx } from "./Button";
import { t } from "@/lib/i18n";

/** What's picked among `pageIds`. A new `reset` (another filter, a search) starts with nothing picked. */
export function useSelection(pageIds: readonly string[], reset: string) {
  const [picked, setPicked] = useState<ReadonlySet<string>>(() => new Set());
  const [shown, setShown] = useState(reset);
  if (shown !== reset) {
    setShown(reset);
    setPicked(new Set());
  }
  return {
    /** Picked and on the page, in its order. */
    ids: pickedOnPage(picked, pageIds),
    state: pageState(picked, pageIds),
    has: (id: string) => picked.has(id),
    toggle: (id: string) => setPicked((p) => toggleOne(p, id)),
    toggleAll: () => setPicked((p) => toggleAll(p, pageIds)),
    clear: () => setPicked(new Set()),
  };
}
export type Selection = ReturnType<typeof useSelection>;

function SelectAllBox({ selection, label }: { selection: Selection; label: string }) {
  const box = useRef<HTMLInputElement>(null);
  // A dash when only some are picked: there's no attribute for it, only the property.
  useEffect(() => {
    if (box.current) box.current.indeterminate = selection.state === "some";
  });
  return <input ref={box} type="checkbox" aria-label={label} checked={selection.state === "all"} onChange={selection.toggleAll} />;
}

/** The heading cell: picks every row on this page (a dash when only some are). */
export function SelectAllCell({ selection, label }: { selection: Selection; label: string }) {
  return <th className="select-cell"><label><SelectAllBox selection={selection} label={label} /></label></th>;
}

/** A row's box. A click on it, or near it, picks the row rather than opening it. */
export function SelectCell({ selection, id, label }: { selection: Selection; id: string; label: string }) {
  return (
    <td className="select-cell" data-pick={id} onClick={(e) => e.stopPropagation()}>
      <label><input type="checkbox" aria-label={label} checked={selection.has(id)} onChange={() => selection.toggle(id)} /></label>
    </td>
  );
}

/** How long a finger rests on a row before it's picked, and how far it can wander meanwhile. */
const HOLD_MS = 500;
const HOLD_SLOP = 10;
/** How long after a hold picked a row the tap that ended it is ignored, rather than opening the row. */
const HOLD_TAP = 800;

/**
 * On a touch screen, holding a finger on a row picks it (or puts it back), as a phone's own lists do,
 * with a short buzz where the phone can; a tap still opens it, and a scroll or a drag is left alone.
 * Spread on the list's <tbody>: the row is the one with a box (SelectCell). Only touches count, and
 * nothing here stops or cancels an ordinary click, so a mouse, a keyboard and the boxes and links in
 * the rows work as before. The tap that ends a hold, and the phone's own long-press menu, are kept
 * from doing anything else.
 */
export function useHoldToPick(selection: Selection) {
  const hold = useRef<{ x: number; y: number; timer: number } | null>(null);
  const pickedAt = useRef(0);
  const cancel = () => {
    if (hold.current) window.clearTimeout(hold.current.timer);
    hold.current = null;
  };
  useEffect(() => cancel, []);
  const justPicked = () => Date.now() - pickedAt.current < HOLD_TAP;
  return {
    // For components.css: a held row's words aren't selected, nor the phone's copy menu shown.
    "data-hold": "",
    onPointerDown(e: ReactPointerEvent) {
      cancel();
      // A new touch: whatever a hold before it was keeping from opening has passed.
      pickedAt.current = 0;
      if (e.pointerType !== "touch" || !e.isPrimary) return;
      const id = (e.target as Element).closest("tr")?.querySelector<HTMLElement>("[data-pick]")?.dataset.pick;
      if (!id) return;
      const timer = window.setTimeout(() => {
        hold.current = null;
        selection.toggle(id);
        pickedAt.current = Date.now();
        navigator.vibrate?.(10);
      }, HOLD_MS);
      hold.current = { x: e.clientX, y: e.clientY, timer };
    },
    onPointerMove(e: ReactPointerEvent) {
      const h = hold.current;
      if (h && Math.hypot(e.clientX - h.x, e.clientY - h.y) > HOLD_SLOP) cancel();
    },
    onPointerUp: cancel,
    onPointerCancel: cancel,
    onContextMenu(e: ReactMouseEvent) {
      if (hold.current || justPicked()) e.preventDefault();
    },
    onClickCapture(e: ReactMouseEvent) {
      if (!justPicked()) return;
      pickedAt.current = 0;
      e.preventDefault();
      e.stopPropagation();
    },
  };
}

/**
 * Above the list, in view as it scrolls: how many are picked, the actions, and Clear. On a phone,
 * where the table's headings are hidden, it's where Select all is too, so it shows before any are.
 */
export function SelectionBar({ selection, noun, children }: { selection: Selection; noun: string; children: ReactNode }) {
  const count = selection.ids.length;
  return (
    <>
      <span className="sr-only" role="status">{count ? t("{count} selected", { count }) : ""}</span>
      <div className={cx("select-bar", !count && "mobile-only")}>
        <label className="select-bar-all">
          <SelectAllBox selection={selection} label={t("Select all {noun} on this page", { noun })} />
          <span aria-hidden="true">{count ? t("{count} selected", { count }) : t("Select all")}</span>
        </label>
        {count > 0 && (
          <>
            <div className="select-bar-actions">{children}</div>
            <Button size="sm" variant="ghost" onClick={selection.clear}>{t("Clear")}</Button>
          </>
        )}
      </div>
    </>
  );
}

/**
 * Archiving picked rows, once the count is confirmed: they leave the list at once with Undo
 * (lib/undo.ts) and are archived when the toast goes, `write` a chunk at a time. Then any that
 * couldn't be (and `skipped`, left out before) are said with why, and the list is fetched again.
 */
export function archiveWithUndo<T>(o: {
  key: QueryKey;
  ids: string[];
  title: string;
  tone?: ToastTone;
  /** The list without the archived rows, or with them shown as archived where its filter keeps them. */
  hide: (data: T, ids: ReadonlySet<string>) => T;
  write: (chunk: string[]) => Promise<readonly string[]>;
  words: BulkWords;
  skipped?: BulkResult;
  refresh: () => Promise<unknown>;
}) {
  const before = queryClient.getQueryData<T>(o.key);
  const picked = new Set(o.ids);
  undoable({
    title: o.title,
    tone: o.tone,
    hide: () => {
      void queryClient.cancelQueries({ queryKey: o.key });
      queryClient.setQueryData<T>(o.key, (data) => (data === undefined ? data : o.hide(data, picked)));
    },
    restore: () => queryClient.setQueryData<T>(o.key, before),
    commit: async () => {
      const result = await inChunks(o.ids, o.write);
      reportBulk(o.skipped ? mergeResults(result, o.skipped) : result, o.words, { said: true, tone: o.tone });
      await o.refresh();
    },
  });
}
