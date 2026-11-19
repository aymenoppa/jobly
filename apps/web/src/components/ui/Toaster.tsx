import { Toast } from "@base-ui/react/toast";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { springBack, springIn } from "@/lib/spring";
import { dismissToast, getToasts, subscribeToasts, type ToastItem } from "@/lib/toast";
import { Spinner } from "./Button";
import { Icon } from "./Icon";
import { supportsPopover, TOP_LAYER_EVENT, topLayerProps } from "./topLayer";
import { t } from "@/lib/i18n";

/** How far each older toast peeks out above the one in front, and the gap between them fanned out. */
const PEEK = 10;
const GAP = 8;
/** A toast's height until it has been measured. */
const GUESS = 52;

const coarsePointer = () => typeof window !== "undefined" && window.matchMedia("(pointer: coarse)").matches;
const lessMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;
/** Out like --dur-exit with --ease-exit (in is a spring: lib/spring.ts). */
const EXIT: KeyframeAnimationOptions = { duration: 180, easing: "cubic-bezier(0.32, 0.72, 0, 1)", fill: "forwards" };

/**
 * A toast's exit, with Web Animations: raising the toaster again hides and shows it, which would
 * replay a CSS animation. Base UI waits for it to finish before taking the toast out. With less
 * motion it only fades.
 */
function animate(node: HTMLElement, from: Keyframe, to: Keyframe, options: KeyframeAnimationOptions) {
  if (typeof node.animate !== "function") return;
  node.animate(lessMotion() ? [{ opacity: from.opacity }, { opacity: to.opacity }] : [from, to], options);
}

/** What Base UI keeps for each toast: the store's own (lib/toast.ts). */
type Shown = Toast.Root.ToastObject<{ item: ToastItem }>;

/**
 * Shows lib/toast.ts's toasts with Base UI's Toast, which runs their timers (waiting while they're
 * hovered, tabbed into or touched, or the window is in the background), stacks them, lets a finger
 * swipe one away and moves keyboard focus on when one closes. F6 jumps to them.
 */
export function Toaster() {
  return (
    <Toast.Provider limit={4}>
      <Stack />
    </Toast.Provider>
  );
}

/**
 * The toaster is in the browser's top layer (a popover), so it appears above open dialogs. It's
 * raised again whenever a toast is added, and when a dialog or the command palette opens
 * ("jobly:toplayer"), so it stacks above anything opened since. While a modal dialog is open it
 * sits inside it, so it can be used there too (useHome).
 *
 * Two or more stack up, newest in front with up to two older ones peeking behind it, and fan out
 * into a list while hovered, tabbed into or (on a touch screen) touched.
 */
function Stack() {
  const { toasts, add, close } = Toast.useToastManager<{ item: ToastItem }>();
  const ref = useRef<HTMLDivElement>(null);
  const count = toasts.length;
  const countRef = useRef(count);
  countRef.current = count;
  // The window in the background holds Base UI's timers too, so the Undo ring waits with them.
  const away = useAway();

  // A swipe or Escape that Base UI turns into a close is the person closing the toast, not its time running out.
  const closing = useRef<number | null>(null);
  const byPerson = useCallback((id: number) => {
    closing.current = id;
    setTimeout(() => {
      if (closing.current === id) closing.current = null;
    }, 0);
  }, []);

  // The store's toasts, handed to Base UI as they come, change and go. Adding one Base UI already has
  // changes it in place and starts its time over (the same message again, a wait that's done).
  const handed = useRef(new Map<number, ToastItem>());
  useEffect(() => {
    const sync = () => {
      const items = getToasts();
      for (const item of items) {
        const before = handed.current.get(item.id);
        if (before === item) continue;
        handed.current.set(item.id, item);
        if (item.leaving) {
          if (before && !before.leaving) close(String(item.id));
          continue;
        }
        add({
          id: String(item.id),
          title: item.title,
          description: item.description,
          type: item.kind,
          timeout: item.duration,
          data: { item },
          // Base UI's own closes: the timer, a swipe, Escape.
          onClose: () => {
            const known = handed.current.get(item.id);
            if (known) handed.current.set(item.id, { ...known, leaving: true });
            dismissToast(item.id, closing.current === item.id ? "dismiss" : "timeout");
          },
        });
      }
      for (const id of handed.current.keys()) if (!items.some((i) => i.id === id)) handed.current.delete(id);
    };
    sync();
    return subscribeToasts(sync);
  }, [add, close]);

  const raise = useCallback(() => {
    const el = ref.current;
    if (!el || !supportsPopover) return;
    try {
      if (el.matches(":popover-open")) el.hidePopover();
      if (countRef.current) el.showPopover();
    } catch {
      // Older browsers: the fallback attribute keeps it visible as a fixed element.
    }
  }, []);

  const home = useHome(raise);
  useLayoutEffect(raise, [count, toasts[0]?.id, raise]);

  // Newest first, as Base UI keeps them. One leaving keeps its place while it fades, and the ones behind move into it.
  const layout = new Map<string, { index: number; offset: number }>();
  let index = 0;
  let offset = 0;
  let frontHeight = 0;
  for (const shown of toasts) {
    layout.set(shown.id, { index, offset });
    if (shown.transitionStatus === "ending") continue;
    const height = shown.height || GUESS;
    if (!index) frontHeight = height;
    offset += height + GAP;
    index += 1;
  }
  const showing = index;
  const stacked = frontHeight + Math.min(Math.max(showing - 1, 0), 2) * PEEK;
  const fanned = offset - GAP;

  return createPortal(
    <Toast.Viewport
      ref={ref}
      className="toaster"
      {...topLayerProps}
      aria-label={t("Notifications")}
      style={(state) => ({ height: (state.expanded && showing > 1 ? fanned : stacked) || undefined })}
    >
      {/* Oldest first in the page, so the newest paints on top. */}
      {[...toasts].reverse().map((shown) => (
        <Item key={shown.id} shown={shown as Shown} place={layout.get(shown.id) ?? { index: 0, offset: 0 }} showing={showing} frontHeight={frontHeight} away={away} byPerson={byPerson} />
      ))}
    </Toast.Viewport>,
    home,
  );
}

const isModal = (dialog: HTMLDialogElement) => {
  try {
    return dialog.matches(":modal");
  } catch {
    return dialog.open;
  }
};

/**
 * Where the toaster sits in the page. A modal dialog leaves everything outside it out of reach
 * (inert), a popover in the top layer included: Undo could be seen above it but not pressed. So
 * while one is open the toaster moves inside the newest, where it's still drawn above it (raised
 * again as it moves) and can be used, and it goes back to the end of the page once that closes.
 * The element itself moves, so the toasts on it carry on as they were.
 */
function useHome(raise: () => void): HTMLElement {
  const [home] = useState(() => {
    const el = document.createElement("div");
    // No box of its own: inside a dialog it takes no room in its layout.
    el.style.display = "contents";
    return el;
  });
  useLayoutEffect(() => {
    // Modal dialogs as they opened, newest last.
    const open: HTMLDialogElement[] = [];
    let watch: MutationObserver | null = null;
    /** Moves the toaster where it belongs now; true when it moved (and so has to be shown again). */
    const settle = (): boolean => {
      for (const dialog of document.querySelectorAll("dialog")) if (isModal(dialog) && !open.includes(dialog)) open.push(dialog);
      for (let i = open.length - 1; i >= 0; i--) if (!open[i]!.isConnected || !isModal(open[i]!)) open.splice(i, 1);
      const host = open.at(-1) ?? document.body;
      // A dialog can be taken out of the page while open (its screen went away), which says nothing:
      // while the toaster is in one, it notices.
      if (host === document.body) {
        watch?.disconnect();
        watch = null;
      } else if (!watch) {
        watch = new MutationObserver(() => {
          const parent = home.parentElement;
          if (parent !== document.body && (!parent || !home.isConnected || !(parent instanceof HTMLDialogElement) || !isModal(parent)) && settle()) raise();
        });
        watch.observe(document.body, { childList: true, subtree: true });
      }
      if (home.parentElement === host) return false;
      host.append(home);
      return true;
    };
    if (settle()) raise();
    // A dialog or the command palette went up: move into it if it's a modal dialog, and stay above it either way.
    const opened = () => {
      settle();
      raise();
    };
    const closed = () => settle() && raise();
    // close doesn't bubble, so it's heard on the way down.
    window.addEventListener("close", closed, true);
    window.addEventListener(TOP_LAYER_EVENT, opened);
    return () => {
      window.removeEventListener("close", closed, true);
      window.removeEventListener(TOP_LAYER_EVENT, opened);
      watch?.disconnect();
      home.remove();
    };
  }, [home, raise]);
  return home;
}

/** Whether the window is in the background (another app or tab in front). */
function useAway() {
  const [away, setAway] = useState(false);
  useEffect(() => {
    const blur = (e: FocusEvent) => e.target === window && setAway(true);
    const focus = () => setAway(false);
    window.addEventListener("blur", blur, true);
    window.addEventListener("focus", focus, true);
    return () => {
      window.removeEventListener("blur", blur, true);
      window.removeEventListener("focus", focus, true);
    };
  }, []);
  return away;
}

interface ItemProps {
  shown: Shown;
  place: { index: number; offset: number };
  showing: number;
  frontHeight: number;
  away: boolean;
  byPerson: (id: number) => void;
}

function Item({ shown, place, showing, frontHeight, away, byPerson }: ItemProps) {
  const item = shown.data!.item;
  const node = useRef<HTMLDivElement>(null);
  // Where a finger left it, so a swipe let go short of dismissing springs back from there.
  const dragged = useRef("");
  const touch = coarsePointer();

  return (
    <Toast.Root
      ref={node}
      toast={shown}
      className="toast"
      // Only a finger swipes a toast away; a mouse selects its text.
      swipeDirection={touch ? ["left", "right"] : []}
      // A status, or an alert for an error, rather than Base UI's dialog: a toast is read out, not entered.
      role={item.kind === "error" ? "alert" : "status"}
      aria-modal={undefined}
      // Focus can still be put on it (when the one before it closes), but Tab goes to its buttons.
      tabIndex={-1}
      data-kind={item.kind}
      data-tone={item.tone}
      onPointerUp={() => {
        dragged.current = node.current?.style.transform ?? "";
        byPerson(item.id);
      }}
      onKeyDown={(e) => e.key === "Escape" && byPerson(item.id)}
      render={(props, state) => {
        const expanded = state.expanded && showing > 1;
        const behind = !expanded && place.index > 0;
        const depth = Math.min(place.index, 2);
        const style: CSSProperties = behind ? { translate: `0 ${-depth * PEEK}px`, scale: String(1 - depth * 0.04), height: frontHeight || undefined } : { translate: `0 ${-place.offset}px` };
        return (
          <div {...props} style={{ ...props.style, ...style }} data-behind={behind ? Math.min(place.index, 3) : undefined}>
            <Face item={item} dragged={dragged} paused={state.expanded || away} swiping={state.swiping} ending={state.transitionStatus === "ending"} swipe={state.swipeDirection} />
          </div>
        );
      }}
    />
  );
}

interface FaceProps {
  item: ToastItem;
  dragged: { current: string };
  paused: boolean;
  swiping: boolean;
  ending: boolean;
  swipe: string | undefined;
}

function Face({ item, dragged, paused, swiping, ending, swipe }: FaceProps) {
  // The toast itself is this content's parent. (Its own ref isn't set yet when these effects first
  // run: React sets a parent's ref after its children's layout effects.)
  const content = useRef<HTMLDivElement>(null);
  const node = useMemo(() => ({ get current() { return content.current?.parentElement ?? null; } }), []);
  const ring = useRef<SVGRectElement>(null);
  const drain = useRef<Animation>();
  const pausedRef = useRef(paused);
  pausedRef.current = paused;
  const firstUpdate = useRef(item.updates);

  // Springs into place from just below.
  useLayoutEffect(() => {
    if (node.current) springIn(node.current, "translateY(14px) scale(0.96)");
  }, [node]);

  // Shown again, or changed in place (a wait that's done): a small nudge says so.
  useEffect(() => {
    const el = node.current;
    if (item.updates === firstUpdate.current || !el || typeof el.animate !== "function" || lessMotion()) return;
    el.animate([{ transform: "scale(1.03)" }, { transform: "none" }], { duration: 260, easing: "cubic-bezier(0.34, 1.4, 0.64, 1)" });
  }, [item.updates, node]);

  // A finger let go short of a swipe: it springs back from where it was left.
  const wasSwiping = useRef(false);
  useLayoutEffect(() => {
    if (swiping) {
      wasSwiping.current = true;
      return;
    }
    if (!wasSwiping.current) return;
    wasSwiping.current = false;
    const from = dragged.current;
    const moved = Math.abs(parseFloat(from.match(/translateX\((-?[\d.]+)px\)/)?.[1] ?? "0"));
    if (!ending && node.current && moved > 1) void springBack(node.current, from);
  }, [swiping, ending, dragged, node]);

  // Leaves where it was dropped, or carries on the way it was swiped.
  useLayoutEffect(() => {
    const el = node.current;
    if (!el || !ending) return;
    const away = swipe === "right" ? "translateX(calc(100% + 32px))" : swipe === "left" ? "translateX(calc(-100% - 32px))" : "translateY(6px) scale(0.97)";
    const from = swipe ? `translateX(${getComputedStyle(el).getPropertyValue("--toast-swipe-movement-x").trim() || "0px"})` : el.style.transform || "none";
    animate(el, { opacity: 1, transform: from }, { opacity: 0, transform: away }, EXIT);
  }, [ending, swipe, node]);

  // The countdown ring drains with Base UI's timer: it starts over when the toast does, and waits with it.
  useLayoutEffect(() => {
    const rect = ring.current;
    if (!rect || typeof rect.animate !== "function" || !item.duration) return;
    const animation = rect.animate([{ strokeDashoffset: 0 }, { strokeDashoffset: 100 }], { duration: item.duration, easing: "linear", fill: "forwards" });
    if (pausedRef.current) animation.pause();
    drain.current = animation;
    return () => animation.cancel();
  }, [item.duration, item.updates]);
  useEffect(() => {
    const animation = drain.current;
    if (!animation || animation.playState === "finished") return;
    if (paused) animation.pause();
    else animation.play();
  }, [paused]);

  const icon: ReactNode = item.kind === "loading" ? <Spinner size={12} /> : <Icon name={item.kind === "success" ? "check" : item.kind === "error" ? "x" : item.kind === "warning" ? "alert" : "info"} size={12} bold />;
  return (
    // Base UI measures the toast again whenever what's in here changes size (a wait that's done says more).
    <Toast.Content ref={content} className="toast-content">
      <span className="toast-icon">{icon}</span>
      <div className="toast-body">
        {item.title}
        {item.description && <div className="toast-desc">{item.description}</div>}
      </div>
      {item.action && (
        <button
          type="button"
          className="toast-action"
          data-toast={item.id}
          onClick={() => {
            item.action!.onClick();
            dismissToast(item.id, "action");
          }}
        >
          {item.action.label}
          {item.countdown && (
            <svg className="toast-ring" aria-hidden="true">
              <rect ref={ring} width="100%" height="100%" rx="9" pathLength={100} />
            </svg>
          )}
        </button>
      )}
      <button type="button" className="toast-x" aria-label={t("Dismiss")} onClick={() => dismissToast(item.id)}><Icon name="x" size={14} /></button>
    </Toast.Content>
  );
}
