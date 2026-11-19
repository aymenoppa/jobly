/**
 * Whether an app is installed, like an app store: turned on, signed in to, a key, a calendar or a
 * website's address added, or (ChatGPT) the person's own plan connected or the team let to connect theirs. Installed apps get a check
 * on the Apps grid, and their pages show the setup and an Uninstall button instead of the listing's
 * Install. An AI assistant connected to Jobly (Settings → AI assistants) isn't an app here.
 */
import type { AppRow } from "./catalog";

export function isInstalled(app: AppRow): boolean {
  if (app.auth === "builtin" || app.auth === "site") return app.status === "connected";
  // Calendars added by link, Google's by secret address too; Stripe and Twilio, also when the server
  // set them up; ChatGPT for someone who connected their own plan, or at a company that lets its
  // team connect theirs, with or without a company key.
  if (app.calendars || app.stripe || app.twilio?.own || app.twilio?.server || app.my_plan || app.team_plans) return true;
  // A Twilio key saved before accounts could be connected never sent anything.
  if (app.id === "twilio") return false;
  // "connector": what Claude and ChatGPT were on a server from before their keys were all they are here.
  if (app.auth === "link" || app.auth === "connector") return false;
  // Signed in or a key added, including one that needs reconnecting. Claude's and OpenAI's keys count.
  return app.status !== "disconnected";
}

/** isInstalled, as a hook: the pages that use it were written when it needed the person's own connections. */
export function useIsInstalled() {
  return { isInstalled };
}
