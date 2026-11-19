/** The schedule's People view: a row for each person, with the visits they're on. */
import { visitPeople, type CrewPeople } from "@jobly/core/visitPeople";
import { conflictsOf, type GridVisit } from "./TimeGrid";

type OnVisit = { crew_id?: string | null; assignees: Array<{ user_id: string }> };
const NO_CREWS: CrewPeople = new Map();

// Who's on a visit is the people listed on it or, with nobody listed, its crew's members
// (visitPeople), as for My day and what field crew can see (private.my_visits). `crews` is who's on
// each crew, from the schedule (crewPeople(crew_members)).
/** On a person's row: the visits they're on. "" is the row for visits nobody's on yet. */
export const onRow = (visit: OnVisit, person: string, crews: CrewPeople = NO_CREWS) => {
  const people = visitPeople(visit, crews);
  return person ? people.includes(person) : people.length === 0;
};

/**
 * On a person's row: events from their own calendar (its owner, set on the Apps page). One with no
 * owner, or whose owner has no row (`rows`), stays on the nobody row.
 */
export const eventOnRow = (owner: string | null | undefined, person: string, rows: Set<string>) => (owner && rows.has(owner) ? owner === person : person === "");

/**
 * Who gets a row: everyone active on the team, and anyone else on a visit shown (a sub, someone
 * who has left), so no visit goes missing. You first, then by name.
 */
export function peopleRows<P extends { user_id: string; active: boolean; sub?: unknown }>(team: P[], visits: OnVisit[], nameOf: (id: string) => string, me: string, crews: CrewPeople = NO_CREWS): P[] {
  const on = new Set(visits.flatMap((v) => visitPeople(v, crews)));
  return team
    .filter((p) => (p.active && !p.sub) || on.has(p.user_id))
    .sort((a, b) => Number(b.user_id === me) - Number(a.user_id === me) || nameOf(a.user_id).localeCompare(nameOf(b.user_id)));
}

/**
 * The people on a visit after it's dropped on `to`'s row, having been dragged from `from`'s (none
 * when it came from Unscheduled): `from` comes off and `to` goes on. null when nobody changes.
 * `current` is who's on it now (visitPeople): moving a crew's visit off one member's row lists the
 * rest of the crew with whoever it was dropped on.
 */
export function movePeople(current: string[], from: string | undefined, to: string): string[] | null {
  if (from === to) return null;
  const next = [...current.filter((id) => id !== from), ...(to && !current.includes(to) ? [to] : [])];
  return next.length === current.length && next.every((id) => current.includes(id)) ? null : next;
}

/**
 * For the visit form: who of `people` is already on another visit at the draft's time, on any of
 * `days` (a multi-day booking is a visit a day at the same time), with the visits and their days.
 */
export function doubleBookings<V extends GridVisit & OnVisit & { scheduled_on: string | null }>(draft: GridVisit, days: string[], people: string[], visits: V[], tz: string, crews: CrewPeople = NO_CREWS) {
  return people.flatMap((id) => {
    // A clash is a time of day, so the draft stands in for each of its days.
    const clashes = days.flatMap((day) => {
      const theirs = visits.filter((v) => v.id !== draft.id && v.scheduled_on === day && onRow(v, id, crews));
      return (conflictsOf([draft, ...theirs], [], tz, id).get(draft.id)?.clashes ?? []).map((c) => ({ ...c, day }));
    });
    return clashes.length ? [{ id, clashes }] : [];
  });
}
