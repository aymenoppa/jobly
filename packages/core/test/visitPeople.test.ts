import { describe, expect, it } from "vitest";
import { crewPeople, onVisit, peopleAfterCrewChange, visitPeople } from "../src/visitPeople";

// Mowing is Ann and Bob, Trees is Cy and (also on Mowing) Bob; Dee is on no crew.
const crews = crewPeople([
  { crew_id: "mowing", user_id: "ann" },
  { crew_id: "mowing", user_id: "bob" },
  { crew_id: "trees", user_id: "cy" },
  { crew_id: "trees", user_id: "bob" },
]);
const listed = (...ids: string[]) => ids.map((user_id) => ({ user_id }));

describe("who is on a visit", () => {
  it("is the people listed on it, whatever its crew", () => {
    expect(visitPeople({ crew_id: "mowing", assignees: listed("dee") }, crews)).toEqual(["dee"]);
    expect(visitPeople({ crew_id: null, assignees: listed("ann", "dee") }, crews)).toEqual(["ann", "dee"]);
    expect(onVisit({ crew_id: "mowing", assignees: listed("dee") }, "ann", crews)).toBe(false);
  });

  it("is its crew's members when nobody is listed (a recurring visit, or one made in bulk)", () => {
    expect(visitPeople({ crew_id: "mowing", assignees: [] }, crews)).toEqual(["ann", "bob"]);
    expect(visitPeople({ crew_id: "mowing" }, crews)).toEqual(["ann", "bob"]);
    expect(onVisit({ crew_id: "mowing", assignees: [] }, "bob", crews)).toBe(true);
    expect(onVisit({ crew_id: "mowing", assignees: [] }, "cy", crews)).toBe(false);
  });

  it("is nobody with no crew, a crew with nobody on it, or a crew that isn't known", () => {
    expect(visitPeople({ crew_id: null, assignees: [] }, crews)).toEqual([]);
    expect(visitPeople({ crew_id: "hedges", assignees: null }, crews)).toEqual([]);
    expect(visitPeople({}, crewPeople(null))).toEqual([]);
  });
});

describe("the people listed when a visit's crew changes", () => {
  it("swaps the old crew's members for the new crew's, keeping anyone picked by hand", () => {
    expect(peopleAfterCrewChange(["ann", "bob", "dee"], "mowing", "trees", crews)).toEqual(["bob", "dee", "cy"]);
    // Only part of the old crew was on it: still the old crew's people, so the new crew's go on.
    expect(peopleAfterCrewChange(["ann"], "mowing", "trees", crews)).toEqual(["cy", "bob"]);
  });

  it("takes the old crew's members off when the visit is left with no crew", () => {
    expect(peopleAfterCrewChange(["ann", "dee"], "mowing", null, crews)).toEqual(["dee"]);
  });

  it("leaves a list picked by hand as it is", () => {
    expect(peopleAfterCrewChange(["dee"], "mowing", "trees", crews)).toEqual(["dee"]);
    expect(peopleAfterCrewChange(["dee"], null, "trees", crews)).toEqual(["dee"]);
  });

  it("brings the crew's people along when nobody is listed yet", () => {
    expect(peopleAfterCrewChange([], null, "mowing", crews)).toEqual(["ann", "bob"]);
    expect(peopleAfterCrewChange([], "mowing", "trees", crews)).toEqual(["cy", "bob"]);
    expect(peopleAfterCrewChange([], "mowing", "", crews)).toEqual([]);
  });
});
