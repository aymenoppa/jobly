/**
 * Dropdowns and number boxes (components/ui/Select.tsx, NumberInput.tsx): how a select's <option>
 * children are read into the list it draws for a mouse, which one it shows, what a change handler
 * hears, and what a number box makes of its value and step. A server render (the tests' own) keeps
 * the native select, as a phone does.
 */
import { createElement, Fragment } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { changeEvent } from "../src/components/ui/changeEvent";
import { numberKeyboard, NumberInput, readNumber } from "../src/components/ui/NumberInput";
import { Select } from "../src/components/ui/Select";
import { allOptions, readOptions, shownOption, textOf } from "../src/components/ui/selectOptions";

const h = createElement;
const option = (props: Record<string, unknown>, ...children: unknown[]) => h("option", props, ...(children as []));

describe("reading a select's options", () => {
  it("reads values, labels, and hidden and disabled options, in order", () => {
    const entries = readOptions([
      option({ key: "a", value: "", hidden: true }, "Pick a crew…"),
      option({ key: "b", value: "c1" }, "North crew"),
      option({ key: "c", value: "c2", disabled: true }, "South crew"),
    ]);
    expect(entries).toEqual([
      { kind: "option", value: "", label: "Pick a crew…", hidden: true, disabled: false },
      { kind: "option", value: "c1", label: "North crew", hidden: false, disabled: false },
      { kind: "option", value: "c2", label: "South crew", hidden: false, disabled: true },
    ]);
  });

  it("reads lists made with map(), options left out with &&, fragments and number values", () => {
    const days = [1, 2, 3].map((n) => option({ key: n, value: n }, n, " days"));
    const entries = readOptions([false && option({ value: "x" }, "Never"), null, h(Fragment, { key: "f" }, option({ value: "0" }, "Same day"), days)]);
    expect(allOptions(entries).map((o) => [o.value, o.label])).toEqual([["0", "Same day"], ["1", "1 days"], ["2", "2 days"], ["3", "3 days"]]);
  });

  it("uses the text as the value when there's no value, and the label attribute over the text", () => {
    const [plain, labelled] = allOptions(readOptions([option({ key: 1 }, "  Weekly \n visits "), option({ key: 2, value: "m", label: "Monthly" }, "Every month")]));
    expect(plain).toMatchObject({ value: "Weekly visits", label: "Weekly visits" });
    expect(labelled).toMatchObject({ value: "m", label: "Monthly" });
  });

  it("keeps groups, and a disabled group's options can't be picked", () => {
    const entries = readOptions([
      option({ key: "n", value: "" }, "No template"),
      h("optgroup", { key: "g1", label: "Yours" }, option({ value: "t1" }, "Spring cleanup")),
      h("optgroup", { key: "g2", label: "Retired", disabled: true }, option({ value: "t2" }, "Old one")),
    ]);
    expect(entries.map((e) => e.kind)).toEqual(["option", "group", "group"]);
    expect(entries[1]).toEqual({ kind: "group", label: "Yours", options: [{ value: "t1", label: "Spring cleanup", hidden: false, disabled: false }] });
    expect(allOptions(entries).find((o) => o.value === "t2")?.disabled).toBe(true);
  });

  it("skips what isn't an option", () => {
    expect(readOptions(["text", 4, h("span", null, "not an option"), option({ value: "a" }, "A")])).toHaveLength(1);
  });

  it("reads the words of elements inside an option", () => {
    expect(textOf(["Net ", h("strong", null, 30), " days"])).toBe("Net 30 days");
  });
});

describe("the option a select shows", () => {
  const entries = readOptions([option({ key: 1, value: "", disabled: true }, "Choose…"), option({ key: 2, value: "a" }, "A"), option({ key: 3, value: "b" }, "B")]);

  it("is the one with the value", () => {
    expect(shownOption(entries, "b")?.label).toBe("B");
    expect(shownOption(entries, "")?.label).toBe("Choose…");
  });

  it("is the first that can be picked when no option has the value, as a native select shows", () => {
    expect(shownOption(entries, "gone")?.value).toBe("a");
    expect(shownOption(entries, undefined)?.value).toBe("a");
  });

  it("is nothing with no options", () => {
    expect(shownOption([], "a")).toBeUndefined();
  });
});

describe("what a change handler hears", () => {
  it("has target.value, currentTarget.value and the field's name", () => {
    const e = changeEvent<HTMLSelectElement>("weekly", "freq", "freq-1");
    expect([e.target.value, e.currentTarget.value, e.target.name, e.target.id]).toEqual(["weekly", "weekly", "freq", "freq-1"]);
    expect(() => e.preventDefault()).not.toThrow();
  });
});

describe("a Select in a server render", () => {
  it("is the native select, with the value picked", () => {
    const html = renderToStaticMarkup(h(Select, { className: "select", value: "b", onChange: () => {}, "aria-label": "Letter" }, option({ key: 1, value: "a" }, "A"), option({ key: 2, value: "b" }, "B")));
    expect(html).toBe('<select class="select" aria-label="Letter"><option value="a">A</option><option value="b" selected="">B</option></select>');
  });
});

describe("a number box", () => {
  it("reads its value: a number, or null for empty and for text that isn't one", () => {
    expect([readNumber("12.5"), readNumber(3), readNumber(""), readNumber("  "), readNumber("abc"), readNumber(null), readNumber(undefined), readNumber(Number.NaN)]).toEqual([12.5, 3, null, null, null, null, null, null]);
  });

  it("asks a phone for a keyboard with a decimal point unless only whole numbers go in", () => {
    expect([numberKeyboard(undefined), numberKeyboard(1), numberKeyboard("1"), numberKeyboard(5)]).toEqual(["numeric", "numeric", "numeric", "numeric"]);
    expect([numberKeyboard(0.1), numberKeyboard("0.01"), numberKeyboard("any")]).toEqual(["decimal", "decimal", "decimal"]);
  });

  it("renders the number, its limits on the hidden number input that forms check, and its buttons", () => {
    const html = renderToStaticMarkup(h(NumberInput, { className: "input input-sm", value: "30", min: 1, max: 365, name: "days", "aria-label": "Days", onChange: () => {} }));
    expect(html).toContain('class="input number-field input-sm"');
    expect(html).toMatch(/<input[^>]*class="number-field-input"[^>]*value="30"/);
    expect(html).toMatch(/inputMode="numeric"|inputmode="numeric"/);
    const hidden = /<input[^>]*type="number"[^>]*>/.exec(html)?.[0] ?? "";
    for (const attr of ['name="days"', 'value="30"', 'min="1"', 'max="365"', 'aria-hidden="true"']) expect(hidden).toContain(attr);
    expect(html).toContain('aria-label="Increase"');
    expect(renderToStaticMarkup(h(NumberInput, { value: 2, steppers: false, onChange: () => {} }))).not.toContain("number-field-step");
  });
});
