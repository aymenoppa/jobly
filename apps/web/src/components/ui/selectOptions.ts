/**
 * Reading a <select>'s <option> and <optgroup> children as data, so Select.tsx can draw the same
 * choices as its own list. Kept apart from the component so it's tested without a browser.
 */
import { Children, Fragment, isValidElement, type ReactElement, type ReactNode } from "react";

export interface SelectOption {
  value: string;
  /** What the person reads: the label attribute, else the option's text. */
  label: string;
  /** Can't be picked (its own disabled, or its group's). */
  disabled: boolean;
  /** Not in the list, though it can still be the value shown (a "Pick one…" prompt). */
  hidden: boolean;
}

export type SelectEntry = ({ kind: "option" } & SelectOption) | { kind: "group"; label: string; options: SelectOption[] };

type OptionProps = { value?: string | number | readonly string[]; label?: string; disabled?: boolean; hidden?: boolean; children?: ReactNode };
type GroupProps = { label?: string; disabled?: boolean; children?: ReactNode };

/** The words inside an option, as the browser shows them: text and numbers run together, spaces collapsed. */
export function textOf(node: ReactNode): string {
  if (node == null || typeof node === "boolean") return "";
  if (typeof node === "string" || typeof node === "number" || typeof node === "bigint") return String(node);
  if (Array.isArray(node)) return node.map(textOf).join("");
  if (isValidElement<{ children?: ReactNode }>(node)) return textOf(node.props.children);
  return "";
}

const collapse = (s: string) => s.replace(/\s+/g, " ").trim();

function readOption(el: ReactElement<OptionProps>, groupDisabled: boolean): SelectOption {
  const { value, label, disabled, hidden, children } = el.props;
  const text = collapse(textOf(children));
  return {
    // Like the browser: an option without a value attribute submits its text.
    value: value === undefined ? text : String(value),
    label: label ?? text,
    disabled: Boolean(disabled) || groupDisabled,
    hidden: Boolean(hidden),
  };
}

/**
 * The options and groups among a select's children, in order. Lists made with map(), conditional
 * options and fragments are all read; anything that isn't an option or a group is skipped.
 */
export function readOptions(children: ReactNode): SelectEntry[] {
  const entries: SelectEntry[] = [];
  const walk = (nodes: ReactNode, group: { options: SelectOption[]; disabled: boolean } | null) => {
    Children.forEach(nodes, (child) => {
      if (!isValidElement(child)) return;
      if (child.type === Fragment) return walk((child.props as { children?: ReactNode }).children, group);
      if (child.type === "option") {
        const option = readOption(child as ReactElement<OptionProps>, group?.disabled ?? false);
        if (group) group.options.push(option);
        else entries.push({ kind: "option", ...option });
        return;
      }
      // An optgroup inside an optgroup isn't allowed by HTML; its options join the outer group.
      if (child.type === "optgroup" && !group) {
        const { label, disabled, children: inner } = child.props as GroupProps;
        const next = { options: [] as SelectOption[], disabled: Boolean(disabled) };
        walk(inner, next);
        entries.push({ kind: "group", label: label ?? "", options: next.options });
      } else if (child.type === "optgroup") walk((child.props as GroupProps).children, group);
    });
  };
  walk(children, null);
  return entries;
}

/** Every option, groups opened up. */
export const allOptions = (entries: readonly SelectEntry[]): SelectOption[] => entries.flatMap((e) => (e.kind === "group" ? e.options : [e]));

/**
 * The option a select shows for `value`: the one with that value, or, when none has it, the first
 * that can be picked, as the browser picks one for a native select. Undefined with no options.
 */
export function shownOption(entries: readonly SelectEntry[], value: string | undefined): SelectOption | undefined {
  const options = allOptions(entries);
  return (value === undefined ? undefined : options.find((o) => o.value === value)) ?? options.find((o) => !o.disabled) ?? options[0];
}
