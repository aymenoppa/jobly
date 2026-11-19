/**
 * How you compare, on Marketing → Reviews (services/reviewCompare.ts): the switch (owners and
 * admins) and the list of place IDs to compare. Google is asked by the browser, never from here,
 * and nothing it says comes here: each body is refused if it carries anything but the fields named.
 */
import { ADMINS, OFFICE } from "@jobly/core";
import { PLACE_ID } from "@jobly/core/reviewCompare";
import { Hono } from "hono";
import { z } from "zod";
import type { AppEnv } from "../env";
import { requireCompany, requireUser } from "../lib/auth";
import { dbError, HttpError, param, readJson, uuid } from "../lib/http";
import { adminClient } from "../lib/supabase";
import { addPlace, comparisonState, setComparison } from "../services/reviewCompare";

export const reviewCompare = new Hono<AppEnv>();

reviewCompare.get("/reviews/compare", requireUser, requireCompany(OFFICE, "marketing"), async (c) =>
  c.json({ ...(await comparisonState(adminClient(c.env), c.var.companyId)), can_switch: ADMINS.includes(c.var.role) }),
);

reviewCompare.put("/reviews/compare/enabled", requireUser, requireCompany(ADMINS, "marketing"), async (c) => {
  const body = await readJson(c, z.object({ enabled: z.boolean() }).strict());
  await setComparison(c.env, adminClient(c.env), c.var.companyId, c.var.userId, body.enabled);
  return c.json({ ...(await comparisonState(adminClient(c.env), c.var.companyId)), can_switch: true });
});

reviewCompare.post("/reviews/compare/places", requireUser, requireCompany(OFFICE, "marketing"), async (c) => {
  const body = await readJson(c, z.object({ place_id: z.string().regex(PLACE_ID, "That isn't a Google place."), own: z.boolean().default(false) }).strict());
  await addPlace(adminClient(c.env), c.var.companyId, body.place_id, body.own);
  return c.json(await comparisonState(adminClient(c.env), c.var.companyId));
});

reviewCompare.delete("/reviews/compare/places/:id", requireUser, requireCompany(OFFICE, "marketing"), async (c) => {
  const id = param(c, "id");
  if (!uuid.safeParse(id).success) throw new HttpError(404, "Not found.");
  const { error } = await adminClient(c.env).from("review_places").delete().eq("company_id", c.var.companyId).eq("id", id);
  if (error) throw dbError(error);
  return c.json(await comparisonState(adminClient(c.env), c.var.companyId));
});
