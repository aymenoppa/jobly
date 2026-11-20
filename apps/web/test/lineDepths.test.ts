/**
 * A depth for each line when a drawing fills a quote (features/quotes/depths.ts), and a price list
 * item's own depth (Settings → Price list): 2 inches of asphalt over 6 of stone used to price the
 * stone at 2.
 */
import { usesDepth } from "@jobly/core/formulas";
import { describe, expect, it } from "vitest";
import { depthLines, lineDepths } from "../src/features/quotes/depths";
import { itemDepth } from "../src/features/settings/PriceList";

const STONE = { id: "l1", name: "Grade and compact stone base", formula: "asphalt_sqyd * depth_in * 110 / 2000", service: { default_depth_in: 6 } };
const HOT_MIX = { id: "l2", name: "Hot-mix asphalt surface", formula: "asphalt_sqyd * depth_in * 110 / 2000", service: { default_depth_in: "2.00" } };
const MULCH = { id: "l3", name: "Mulch", formula: "area_sqft * depth_in / 324", service: { default_depth_in: null } };
const SEAL = { id: "l4", name: "Sealcoat", formula: "sealcoat_sqft", service: null };
const TYPED = { id: "l5", name: "Typed by hand", formula: null, service: null };
const BROKEN = { id: "l6", name: "Broken formula", formula: "depth_in *", service: null };

describe("the depth each line gets when a drawing fills a quote", () => {
  it("asks only about lines whose formula reads a depth, each starting with its item's own", () => {
    expect(depthLines([STONE, HOT_MIX, MULCH, SEAL, TYPED, BROKEN], 3, usesDepth)).toEqual([
      { id: "l1", name: "Grade and compact stone base", depth: "6" },
      { id: "l2", name: "Hot-mix asphalt surface", depth: "2.00" },
      // No depth of its own: the drawing's.
      { id: "l3", name: "Mulch", depth: "3" },
    ]);
    // With no depth on the drawing either, it's left for the office to fill in.
    expect(depthLines([MULCH], null, usesDepth)).toEqual([{ id: "l3", name: "Mulch", depth: "" }]);
    expect(depthLines([SEAL, TYPED], 2, usesDepth)).toEqual([]);
  });

  it("sends a depth for every line, once each is one", () => {
    expect(lineDepths([{ id: "l1", name: "Stone", depth: "6" }, { id: "l2", name: "Hot mix", depth: "2.5" }])).toEqual({ l1: 6, l2: 2.5 });
    for (const depth of ["", " ", "0", "49", "deep", "-2"]) expect(lineDepths([{ id: "l1", name: "Stone", depth: "6" }, { id: "l2", name: "Hot mix", depth }]), depth).toBeNull();
    expect(lineDepths([])).toEqual({});
  });

  it("takes a price list item's depth as inches, or none", () => {
    expect(itemDepth("6")).toBe(6);
    expect(itemDepth(" 2.5 ")).toBe(2.5);
    expect(itemDepth("1.005")).toBe(1);
    expect(itemDepth("")).toBeNull();
    for (const text of ["0", "-1", "48.5", "six"]) expect(itemDepth(text), text).toBeUndefined();
    expect(itemDepth("48")).toBe(48);
  });
});
