import type { ChangeEvent } from "react";

/**
 * What a change handler is given when no browser event made the change (a pick from Select's list,
 * a NumberInput's arrows): enough of an event for code that reads e.target.value, as every handler
 * in the app does, with e.target.name and e.target.id beside it.
 */
export function changeEvent<T extends Element>(value: string, name = "", id = ""): ChangeEvent<T> {
  const target = { value, name, id } as unknown as T;
  return {
    target,
    currentTarget: target,
    type: "change",
    bubbles: true,
    defaultPrevented: false,
    preventDefault() {},
    stopPropagation() {},
    persist() {},
    isDefaultPrevented: () => false,
    isPropagationStopped: () => false,
  } as unknown as ChangeEvent<T>;
}
