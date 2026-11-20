/**
 * Signs in through the real sign-in screen once per demo account and saves the browser state, so
 * the other tests start signed in (Supabase keeps the session in localStorage). The demo sub has no
 * password: they're signed in with a one-time link made with the server's key, the way the office's
 * Text sign-in link signs a sub in.
 */
import { test as setup, expect } from "@playwright/test";
import { createClient } from "@supabase/supabase-js";
import { authFile, PASSWORD, PEOPLE, SUPABASE_SECRET, SUPABASE_URL, withPassword, type Person } from "./support/env";

// Everyone who clocks in is shown, once, what's saved about where they are, in a dialog over My day
// (features/field/LocationNoticeDialog.tsx). The demo team has seen it, so the other tests start past it;
// field.spec.ts has the test of the notice itself.
setup("the demo team has acknowledged the location notice", async () => {
  if (!SUPABASE_URL || !SUPABASE_SECRET) throw new Error("No Supabase server key: fill in .dev.vars (see e2e/README.md).");
  const admin = createClient(SUPABASE_URL, SUPABASE_SECRET, { auth: { persistSession: false, autoRefreshToken: false } });
  const people = await admin.from("profiles").select("user_id").in("email", Object.values(PEOPLE).map((p) => p.email));
  if (people.error) throw new Error(`Couldn't read the demo team (${people.error.message}). Run npm run seed:demo.`);
  const ids = (people.data ?? []).map((p) => p.user_id);
  const members = await admin.from("memberships").select("company_id, user_id").in("user_id", ids);
  if (members.error) throw new Error(`Couldn't read the demo team's companies (${members.error.message}).`);
  const rows = (members.data ?? []).flatMap((m) => (["clock_location", "clock_at_property"] as const).map((notice) => ({ company_id: m.company_id, user_id: m.user_id, notice })));
  const saved = await admin.from("worker_notices").upsert(rows, { onConflict: "company_id,user_id,notice", ignoreDuplicates: true });
  if (saved.error) throw new Error(`Couldn't record the location notice for the demo team (${saved.error.message}).`);
});

setup("sign in as the sub, with a one-time link", async ({ page }) => {
  if (!SUPABASE_URL || !SUPABASE_SECRET) throw new Error("No Supabase server key: fill in .dev.vars (see e2e/README.md).");
  const admin = createClient(SUPABASE_URL, SUPABASE_SECRET, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email: PEOPLE.sub.email });
  if (error || !data.properties?.hashed_token) throw new Error(`Couldn't make the demo sub's sign-in link (${error?.message ?? "no token"}). Run npm run seed:demo.`);
  await page.goto(`/?token_hash=${encodeURIComponent(data.properties.hashed_token)}&type=magiclink`);
  // A sub lands on My day.
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible({ timeout: 20_000 });
  await expect(page.getByRole("heading", { name: "Sign in" })).toHaveCount(0);
  await page.context().storageState({ path: authFile("sub") });
});

for (const who of (Object.keys(PEOPLE) as Person[]).filter(withPassword)) {
  setup(`sign in as ${who}`, async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "Sign in" })).toBeVisible();
    await page.getByLabel("Email").fill(PEOPLE[who].email);
    await page.getByLabel("Password", { exact: true }).fill(PASSWORD);
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    // Everyone lands on Home with their first name in the greeting.
    const home = page.getByRole("heading", { level: 1, name: new RegExp(PEOPLE[who].name.split(" ")[0]!) });
    // A demo company seeded before the license step asks its owner and admins to agree once.
    const terms = page.getByRole("heading", { level: 1, name: "Before you continue" });
    await expect(home.or(terms)).toBeVisible({ timeout: 20_000 });
    if (await terms.isVisible()) {
      await page.getByRole("checkbox", { name: /agree to the Jobly Terms/ }).check();
      await page.getByRole("button", { name: "Agree and continue" }).click();
    }
    await expect(home).toBeVisible({ timeout: 20_000 });
    await page.context().storageState({ path: authFile(who) });
  });
}
