/**
 * Who is on visits, read with the server's key: the people listed on each or, with nobody listed,
 * its crew's members (visitPeople() in @jobly/core; the database's private.visit_people()).
 */
import { crewPeople, visitPeople, type CrewPeople } from "@jobly/core";
import type { Db } from "../lib/supabase";

/** The members of these crews, by crew. */
export async function membersOfCrews(db: Db, companyId: string, crewIds: Array<string | null | undefined>): Promise<CrewPeople> {
  const ids = [...new Set(crewIds.filter((id): id is string => Boolean(id)))];
  if (!ids.length) return new Map();
  const { data, error } = await db.from("crew_members").select("crew_id, user_id").eq("company_id", companyId).in("crew_id", ids).limit(1000);
  if (error) throw new Error(error.message);
  return crewPeople(data);
}

/** The people on each of these visits (a few dozen at most: they're named in one address), by visit. */
export async function peopleOnVisits(db: Db, companyId: string, visitIds: string[]): Promise<Map<string, string[]>> {
  if (!visitIds.length) return new Map();
  const { data, error } = await db.from("visits").select("id, crew_id, assignees:visit_assignees(user_id)").eq("company_id", companyId).in("id", visitIds);
  if (error) throw new Error(error.message);
  // Only the crews of visits with nobody listed are needed.
  const crews = await membersOfCrews(db, companyId, (data ?? []).filter((v) => !v.assignees.length).map((v) => v.crew_id));
  return new Map((data ?? []).map((v) => [v.id, visitPeople(v, crews)]));
}
