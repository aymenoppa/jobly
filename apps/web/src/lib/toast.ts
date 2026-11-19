/**
 * Toast notifications: brief feedback after an action ("Quote sent", "Couldn't save").
 * A tiny external store so any module (React Query handlers included) can raise one. It knows what's
 * showing and why each one left; components/ui/Toaster.tsx shows them with Base UI's Toast, which
 * runs their timers and tells this store when one runs out or is swiped away.
 */
export type ToastKind = "success" | "error" | "info" | "warning" | "loading";
/** Why a toast left: its action was pressed, its time ran out (or newer toasts pushed it out), or it was closed. */
export type ToastCloseReason = "action" | "timeout" | "dismiss";
/** A workflow color for the icon, so a toast about a quote looks like quotes do. */
export type ToastTone = "request" | "quote" | "job" | "invoice";

export interface ToastOptions {
  description?: string;
  action?: { label: string; onClick: () => void };
  duration?: number;
  /** Called once when the toast leaves, with why. */
  onClose?: (reason: ToastCloseReason) => void;
  /** A ring around the action button that drains over the toast's duration (pauses while hovered). */
  countdown?: boolean;
  tone?: ToastTone;
}

export interface ToastItem extends ToastOptions {
  id: number;
  kind: ToastKind;
  title: string;
  /** How long it shows, in milliseconds; 0 while it waits on something (toast.promise). */
  duration: number;
  /** How many times it was shown again or changed in place; its time starts over each time. */
  updates: number;
  leaving?: boolean;
}

/** What one state of toast.promise says: a title, or a title with the usual options (and another kind, say a warning). */
export type ToastMessage = string | (ToastOptions & { title: string; kind?: ToastKind });

export interface ToastPromiseMessages<T> {
  /** Shown while it waits ("Sending…"). It has no timer. */
  loading: string | (ToastOptions & { title: string });
  /** What it turns into once the work is done, from its result. Null closes it instead. */
  success: ToastMessage | null | ((value: T) => ToastMessage | null);
  /** What it turns into if the work fails, from the error. */
  error: ToastMessage | ((error: unknown) => ToastMessage);
}

/** At most this many show at once (three peeking behind the newest); older ones are pushed out. */
const MAX = 4;

let items: ToastItem[] = [];
let nextId = 1;
const listeners = new Set<() => void>();

function emit() {
  for (const listener of listeners) listener();
}

function closed(item: ToastItem, reason: ToastCloseReason) {
  try {
    item.onClose?.(reason);
  } catch (error) {
    console.error("A toast's onClose failed", error);
  }
}

const durationFor = (kind: ToastKind, options: ToastOptions) =>
  options.duration ?? (kind === "loading" ? 0 : options.action || kind === "error" || kind === "warning" ? 6000 : 3500);

export function subscribeToasts(listener: () => void) {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export const getToasts = () => items;

export function dismissToast(id: number, reason: ToastCloseReason = "dismiss") {
  const item = items.find((t) => t.id === id && !t.leaving);
  if (!item) return;
  items = items.map((t) => (t.id === id ? { ...t, leaving: true } : t));
  emit();
  closed(item, reason);
  setTimeout(() => {
    items = items.filter((t) => t.id !== id);
    emit();
  }, 180);
}

function push(kind: ToastKind, title: string, options: ToastOptions = {}): number {
  // The same message again while it's still showing (several failing requests at once, a button
  // pressed twice) shows once: the one showing starts its time over. Toasts that hand back a choice
  // (Undo) always show, since each one stands for its own change, and so does each wait on something.
  const plain = !options.action && !options.onClose && kind !== "loading";
  const same = plain && items.find((t) => !t.leaving && !t.action && !t.onClose && t.kind === kind && t.title === title && (t.description ?? "") === (options.description ?? ""));
  if (same) {
    items = items.map((t) => (t.id === same.id ? { ...t, updates: t.updates + 1 } : t));
    emit();
    return same.id;
  }

  // Older toasts pushed out by newer ones leave as if their time ran out.
  const showing = items.filter((t) => !t.leaving);
  for (const old of showing.slice(0, Math.max(showing.length - (MAX - 1), 0))) dismissToast(old.id, "timeout");

  const id = nextId++;
  items = [...items, { id, kind, title, ...options, duration: durationFor(kind, options), updates: 0 }];
  emit();
  return id;
}

/**
 * Changes a toast in place (a wait on something that's done), starting its time over. One that has
 * already left is shown afresh instead, so the outcome is never missed.
 */
function change(id: number, kind: ToastKind, title: string, options: ToastOptions = {}): number {
  const item = items.find((t) => t.id === id && !t.leaving);
  if (!item) return push(kind, title, options);
  items = items.map((t) => (t.id === id ? { id, kind, title, ...options, duration: durationFor(kind, options), updates: t.updates + 1 } : t));
  emit();
  return id;
}

function settle(id: number, fallback: ToastKind, message: ToastMessage | null) {
  if (message === null) return dismissToast(id);
  const { title, kind = fallback, ...options } = typeof message === "string" ? { title: message } : message;
  change(id, kind, title, options);
}

/**
 * One toast for some work that takes a moment: it says `loading` while it waits, then turns into
 * `success` or `error` in place. Returns the work's own promise, so the caller can still await it.
 *
 *   await toast.promise(api.post("/invoices/remind", body), {
 *     loading: "Sending reminders…",
 *     success: (r) => `${r.sent} reminders sent`,
 *     error: (e) => errorMessage(e),
 *   });
 */
function promise<T>(work: Promise<T>, messages: ToastPromiseMessages<T>): Promise<T> {
  const { title, ...options } = typeof messages.loading === "string" ? { title: messages.loading } : messages.loading;
  const id = push("loading", title, options);
  work.then(
    (value) => {
      try {
        settle(id, "success", typeof messages.success === "function" ? messages.success(value) : messages.success);
      } catch (error) {
        console.error("A toast's success message failed", error);
        dismissToast(id);
      }
    },
    (error: unknown) => {
      try {
        settle(id, "error", typeof messages.error === "function" ? messages.error(error) : messages.error);
      } catch (failed) {
        console.error("A toast's error message failed", failed);
        dismissToast(id);
      }
    },
  );
  return work;
}

export const toast = {
  success: (title: string, options?: ToastOptions) => push("success", title, options),
  error: (title: string, options?: ToastOptions) => push("error", title, options),
  info: (title: string, options?: ToastOptions) => push("info", title, options),
  /** It worked, but not all of it: says what didn't, and stays as long as an error. */
  warning: (title: string, options?: ToastOptions) => push("warning", title, options),
  promise,
  dismiss: (id: number) => dismissToast(id),
};
