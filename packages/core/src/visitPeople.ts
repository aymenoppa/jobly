/**
 * Who is on a visit: the people listed on it, or when nobody is listed, the members of its crew.
 * One rule everywhere: the schedule's People rows, My day, the double-booking warning, calendar
 * feeds and the Client Hub go by this, and the database by the same rule in SQL
 * (private.visit_people, 20261113000210_visit_people.sql), which decides what field crew can see
 * and who hears when a visit changes.
 */

/** A visit as the schedule reads it: its crew, and the people listed on it. */
export interface VisitCrewAndPeople {
  crew_id?: string | null;
  assignees?: ReadonlyArray<{ user_id: string }> | null;
}

/** Someone on a crew (a crew_members row). */
export interface CrewMember {
  crew_id: string;
  user_id: string;
}

/** Each crew's members, by crew. */
export type CrewPeople = ReadonlyMap<string, readonly string[]>;

/** crew_members rows as each crew's members. */
export function crewPeople(members: ReadonlyArray<CrewMember> | null | undefined): Map<string, string[]> {
  const crews = new Map<string, string[]>();
  for (const m of members ?? []) {
    const people = crews.get(m.crew_id);
    if (people) people.push(m.user_id);
    else crews.set(m.crew_id, [m.user_id]);
  }
  return crews;
}

/** The people on a visit: the ones listed, else its crew's members. */
export function visitPeople(visit: VisitCrewAndPeople, crews: CrewPeople): string[] {
  const listed = (visit.assignees ?? []).map((a) => a.user_id);
  if (listed.length) return listed;
  return visit.crew_id ? [...(crews.get(visit.crew_id) ?? [])] : [];
}

/** Whether someone is on a visit. */
export const onVisit = (visit: VisitCrewAndPeople, user: string, crews: CrewPeople): boolean => visitPeople(visit, crews).includes(user);

/**
 * The people listed on a visit after its crew changes from `from` to `to`, as the database does it
 * when a visit is dragged to another crew (private.visit_crew_people): with members of the old crew
 * among them, those come off and the new crew's go on, and anyone picked by hand who isn't on the
 * old crew stays. A list with none of the old crew on it was picked by hand and stays as it is;
 * with nobody listed, picking a crew brings its people along (the visit form's way).
 */
export function peopleAfterCrewChange(listed: readonly string[], from: string | null | undefined, to: string | null | undefined, crews: CrewPeople): string[] {
  const incoming = to ? (crews.get(to) ?? []) : [];
  if (!listed.length) return [...incoming];
  const outgoing = from ? (crews.get(from) ?? []) : [];
  if (!listed.some((id) => outgoing.includes(id))) return [...listed];
  const staying = listed.filter((id) => !outgoing.includes(id) || incoming.includes(id));
  return [...staying, ...incoming.filter((id) => !staying.includes(id))];
}
