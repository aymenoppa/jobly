/**
 * The toast store (lib/toast.ts): one toast for a wait that turns into how it went, the same message
 * shown once while it's showing, and why each one left. Components/ui/Toaster.tsx shows them.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";

type Store = typeof import("../src/lib/toast");
let store: Store;

beforeEach(async () => {
  vi.resetModules();
  store = await import("../src/lib/toast");
});

const showing = () => store.getToasts().filter((t) => !t.leaving);

/** A promise and the hands that settle it. */
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

describe("toast.promise", () => {
  it("says it's sending, then turns into what happened in place", async () => {
    const work = deferred<{ sent: number }>();
    const result = store.toast.promise(work.promise, { loading: "Sending reminders…", success: (r) => `${r.sent} reminders sent`, error: "Not sent" });
    expect(showing()).toHaveLength(1);
    const [waiting] = showing();
    expect(waiting).toMatchObject({ kind: "loading", title: "Sending reminders…", duration: 0, updates: 0 });

    work.resolve({ sent: 3 });
    await expect(result).resolves.toEqual({ sent: 3 });
    expect(showing()).toHaveLength(1);
    // The same toast, changed: its time starts now.
    expect(showing()[0]).toMatchObject({ id: waiting!.id, kind: "success", title: "3 reminders sent", duration: 3500, updates: 1 });
  });

  it("turns into the error when the work fails, and the caller still hears of it", async () => {
    const work = deferred<void>();
    const result = store.toast.promise(work.promise, { loading: { title: "Sending…", tone: "invoice" }, success: "Sent", error: (e) => ({ title: "Not sent", description: (e as Error).message }) });
    const id = showing()[0]!.id;
    expect(showing()[0]).toMatchObject({ kind: "loading", tone: "invoice" });

    work.reject(new Error("The mail server said no."));
    await expect(result).rejects.toThrow("The mail server said no.");
    expect(showing()).toEqual([expect.objectContaining({ id, kind: "error", title: "Not sent", description: "The mail server said no.", duration: 6000 })]);
    // Each state says all of itself: the wait's tone isn't carried over.
    expect(showing()[0]!.tone).toBeUndefined();
  });

  it("can turn into another kind, or close when there's nothing to say", async () => {
    const partly = store.toast.promise(Promise.resolve(2), { loading: "Sending…", success: (n) => ({ kind: "warning", title: `${n} not sent` }), error: "Not sent" });
    await partly;
    expect(showing()).toEqual([expect.objectContaining({ kind: "warning", title: "2 not sent" })]);

    const quiet = store.toast.promise(Promise.resolve(), { loading: "Checking…", success: null, error: "Not checked" });
    await quiet;
    expect(showing().map((t) => t.title)).toEqual(["2 not sent"]);
  });

  it("shows how it went afresh when the wait was closed meanwhile", async () => {
    const work = deferred<void>();
    void store.toast.promise(work.promise, { loading: "Sending…", success: "Sent", error: "Not sent" });
    const waiting = showing()[0]!;
    store.toast.dismiss(waiting.id);
    expect(showing()).toHaveLength(0);

    work.resolve();
    await work.promise;
    await Promise.resolve();
    expect(showing()).toEqual([expect.objectContaining({ kind: "success", title: "Sent" })]);
    expect(showing()[0]!.id).not.toBe(waiting.id);
  });

  it("gives each wait its own toast, even with the same words", () => {
    void store.toast.promise(new Promise(() => undefined), { loading: "Sending…", success: "Sent", error: "Not sent" });
    void store.toast.promise(new Promise(() => undefined), { loading: "Sending…", success: "Sent", error: "Not sent" });
    expect(showing()).toHaveLength(2);
  });
});

describe("the same message again", () => {
  it("shows once while it's showing, starting its time over", () => {
    const first = store.toast.error("Couldn't refresh", { description: "No connection" });
    const again = store.toast.error("Couldn't refresh", { description: "No connection" });
    expect(again).toBe(first);
    expect(showing()).toEqual([expect.objectContaining({ id: first, updates: 1 })]);
  });

  it("is a new toast with other words, another kind or once the first has gone", () => {
    const first = store.toast.error("Couldn't refresh", { description: "No connection" });
    store.toast.error("Couldn't refresh", { description: "Something else" });
    store.toast.info("Couldn't refresh", { description: "No connection" });
    expect(showing()).toHaveLength(3);

    store.toast.dismiss(first);
    expect(store.toast.error("Couldn't refresh", { description: "No connection" })).not.toBe(first);
  });

  it("never merges toasts that hand back a choice: each Undo is its own change", () => {
    const undo = { label: "Undo", onClick: () => undefined };
    expect(store.toast.success("Note deleted", { action: undo })).not.toBe(store.toast.success("Note deleted", { action: undo }));
    expect(showing()).toHaveLength(2);
  });
});

describe("why a toast left", () => {
  it("tells onClose once: the action, a close, or pushed out by newer ones as if its time ran out", () => {
    const reasons: string[] = [];
    const onClose = (reason: string) => reasons.push(reason);
    const pressed = store.toast.success("Archived", { action: { label: "Undo", onClick: () => reasons.push("undone") }, onClose });
    store.getToasts().find((t) => t.id === pressed)!.action!.onClick();
    store.dismissToast(pressed, "action");
    store.dismissToast(pressed, "dismiss");
    expect(reasons).toEqual(["undone", "action"]);

    store.toast.success("Oldest", { action: { label: "Undo", onClick: () => undefined }, onClose });
    for (const n of [1, 2, 3]) store.toast.success(`Newer ${n}`);
    expect(reasons).toEqual(["undone", "action"]);
    store.toast.success("Newest");
    expect(reasons).toEqual(["undone", "action", "timeout"]);
    expect(showing().map((t) => t.title)).toEqual(["Newer 1", "Newer 2", "Newer 3", "Newest"]);
  });
});
