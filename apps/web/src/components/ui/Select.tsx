/**
 * A drop-in for <select>, with the same props: value or defaultValue, onChange, name, required,
 * disabled, id, className, aria-*, and <option>/<optgroup> children (hidden and disabled ones too).
 *
 * With a mouse or trackpad it opens the app's own list (Base UI's Select, MIT): a check by the one
 * picked, type a few letters to jump, and it stays on screen, inside the dialog it's in. On a phone or
 * tablet it's the native select, since the phone's own picker is the better one there.
 *
 * With className "select-plain" its button has no box or arrow of its own: it's a select inside a
 * pill that draws them ("Date range | This month ▾", "Crew | All"), styled by the pill's CSS like the
 * native select was, and its list opens under the whole pill.
 *
 * onChange hears an object with target.value (and currentTarget.value, target.name), which is all the
 * app's selects read. Not for what every page loads (components/shell, the sign-in page, Dialog.tsx and
 * what they import): it would put Base UI in the first download.
 */
import { Select as Base } from "@base-ui/react/select";
import { useRef, useState, useSyncExternalStore, type ComponentPropsWithoutRef } from "react";
import { changeEvent } from "./changeEvent";
import { useChangeNotice, useFieldOnTrigger } from "./fieldLink";
import { Icon } from "./Icon";
import { layerFor } from "./layer";
import { readOptions, shownOption, type SelectOption } from "./selectOptions";
import "./pickers.css";

const FINE = "(pointer: fine)";
const subscribe = (change: () => void) => {
  const query = window.matchMedia(FINE);
  query.addEventListener("change", change);
  return () => query.removeEventListener("change", change);
};
/** Whether the main pointer is a mouse or a trackpad. False in a server render, so tests see the native select. */
export const useFinePointer = () => useSyncExternalStore(subscribe, () => window.matchMedia(FINE).matches, () => false);

export type SelectProps = ComponentPropsWithoutRef<"select">;

export function Select(props: SelectProps) {
  const fine = useFinePointer();
  return fine && !props.multiple && !props.size ? <ListSelect {...props} /> : <select {...props} />;
}

function ListSelect({ value, defaultValue, onChange, children, name, required, disabled, id, form, autoComplete, className, ...rest }: SelectProps) {
  const entries = readOptions(children);
  const [own, setOwn] = useState(() => (defaultValue == null ? undefined : String(defaultValue)));
  const controlled = value !== undefined;
  const shown = shownOption(entries, controlled ? (value == null ? "" : String(value)) : own);
  const trigger = useRef<HTMLButtonElement>(null);
  const hidden = useRef<HTMLInputElement>(null);
  // Where the list goes, worked out as it opens: a dialog that's open by then, or the page
  // (undefined: Base UI waits for a container given as null, and puts it in <body> for none).
  const [layer, setLayer] = useState<HTMLElement | undefined>(undefined);
  useFieldOnTrigger(trigger, hidden, { label: "aria-label" in rest || "aria-labelledby" in rest, described: "aria-describedby" in rest, invalid: "aria-invalid" in rest });
  useChangeNotice(hidden, shown?.value);
  const given = (className ?? "").split(/\s+/).filter((c) => c && c !== "select");
  const plain = given.includes("select-plain");
  const classes = [...(plain ? [] : ["select"]), "select-trigger", ...given].join(" ");

  return (
    <Base.Root<string>
      value={shown?.value ?? null}
      onValueChange={(next) => {
        const picked = next ?? "";
        // Picking the option already chosen (a click on the ticked row to close the list) changes
        // nothing, as with the browser's own select: no change is said, so nothing is saved again.
        if (picked === (shown?.value ?? "")) return;
        if (!controlled) setOwn(picked);
        onChange?.(changeEvent<HTMLSelectElement>(picked, name, id));
      }}
      onOpenChange={(open) => open && setLayer(layerFor(trigger.current) ?? undefined)}
      name={name}
      required={required}
      disabled={disabled}
      id={id}
      form={form}
      autoComplete={autoComplete}
      inputRef={hidden}
    >
      {/* The list first, so the button sits right before Base UI's hidden input. */}
      <Base.Portal container={layer}>
        <Base.Positioner
          className="picker-positioner"
          anchor={plain ? () => trigger.current?.parentElement ?? null : undefined}
          side="bottom"
          align="start"
          sideOffset={4}
          alignItemWithTrigger={false}
          positionMethod="fixed"
          collisionPadding={8}
        >
          <Base.Popup className="picker-popup">
            <Base.List>
              {entries.map((entry, i) =>
                entry.kind === "group" ? (
                  entry.options.some((o) => !o.hidden) && (
                    <Base.Group key={`g${i}`} className="picker-group">
                      <Base.GroupLabel className="picker-group-label">{entry.label}</Base.GroupLabel>
                      {entry.options.map((o, j) => choice(o, `${i}.${j}`))}
                    </Base.Group>
                  )
                ) : (
                  choice(entry, String(i))
                ),
              )}
            </Base.List>
          </Base.Popup>
        </Base.Positioner>
      </Base.Portal>
      <Base.Trigger ref={trigger} className={classes} {...(rest as ComponentPropsWithoutRef<"button">)}>
        <Base.Value className="select-value">{() => shown?.label ?? ""}</Base.Value>
      </Base.Trigger>
    </Base.Root>
  );
}

function choice(option: SelectOption, key: string) {
  if (option.hidden) return null;
  return (
    <Base.Item key={key} value={option.value} label={option.label} disabled={option.disabled} className="picker-item">
      <Base.ItemIndicator className="picker-check">
        <Icon name="check" size={14} bold />
      </Base.ItemIndicator>
      <Base.ItemText className="picker-item-text">{option.label}</Base.ItemText>
    </Base.Item>
  );
}

