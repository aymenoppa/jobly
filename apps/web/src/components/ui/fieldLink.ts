/**
 * For Base UI's form controls, whose value a form sees in a hidden input beside them (Select,
 * NumberInput): ties that input and the control people use together for a Field (Field.tsx).
 */
import { useEffect, useRef, type RefObject } from "react";

/**
 * A Field (Field.tsx) labels, describes and marks invalid the first form control in it, which here is
 * Base UI's hidden input: a button isn't one. The button is what's focused and read out, so it takes
 * the same label, note and red edge from the input, unless the select was given its own.
 */
export function useFieldOnTrigger(trigger: RefObject<HTMLElement>, input: RefObject<HTMLInputElement>, own: { label: boolean; described: boolean; invalid: boolean }) {
  useEffect(() => {
    const from = input.current;
    const to = trigger.current;
    if (!from || !to) return;
    const names = [!own.label && "aria-labelledby", !own.described && "aria-describedby", !own.invalid && "aria-invalid"].filter((n): n is string => Boolean(n));
    const copy = () => {
      for (const name of names) {
        const value = from.getAttribute(name);
        if (value === null) to.removeAttribute(name);
        else to.setAttribute(name, value);
      }
    };
    copy();
    const watch = new MutationObserver(copy);
    watch.observe(from, { attributes: true, attributeFilter: names });
    return () => watch.disconnect();
  }, [trigger, input, own.label, own.described, own.invalid]);
}

/**
 * A native select tells its form when it changes; this tells it too, from the hidden input, so a
 * form's "2 fields need a look" (FormChecks) counts again once a missing choice is made.
 */
export function useChangeNotice(input: RefObject<HTMLInputElement>, value: string | undefined) {
  const last = useRef(value);
  useEffect(() => {
    if (last.current === value) return;
    last.current = value;
    input.current?.dispatchEvent(new Event("change", { bubbles: true }));
  }, [input, value]);
}
