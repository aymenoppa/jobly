/**
 * Job showcases: a finished job's before and after photos and a short write-up, on a page anyone
 * with the link can see (supabase/migrations/20261113001410_showcases.sql). Shared by the API, which
 * checks a showcase before it publishes it, and the web app, which says the same before anyone
 * presses Publish: what a showcase needs, what keeps it from being published, and the order its
 * photos go in.
 */
import { CANT_SHARE, CLIENT_OPT_OUT, type CantShare } from "./social";

export const SHOWCASE_ROLES = ["before", "after", "photo"] as const;
export type ShowcaseRole = (typeof SHOWCASE_ROLES)[number];
export const ROLE_LABELS: Record<ShowcaseRole, string> = { before: "Before", after: "After", photo: "Photo" };

/** The most photos a showcase shows. */
export const MAX_SHOWCASE_PHOTOS = 12;
export const MAX_TITLE = 120;
export const MAX_DESCRIPTION = 2000;

/** What a showcase needs before it can be published, or null. */
export function showcaseProblem(s: { title: string; description: string; photos: number }): string | null {
  if (!s.title.trim()) return "Give the showcase a title.";
  if (s.title.trim().length > MAX_TITLE) return `Keep the title to ${MAX_TITLE} characters.`;
  if (s.description.length > MAX_DESCRIPTION) return `Keep the write-up to ${MAX_DESCRIPTION.toLocaleString("en-US")} characters.`;
  if (!s.photos) return "Pick at least one photo.";
  if (s.photos > MAX_SHOWCASE_PHOTOS) return `Pick up to ${MAX_SHOWCASE_PHOTOS} photos.`;
  return null;
}

/** A photo as the database sees it when a showcase is published (public.social_photo_facts). */
export interface ShowcasePhotoFact {
  id: string;
  shareable: boolean;
  /** Why it can't be shared at all: format, no_client or client_opt_out. */
  problem: string | null;
  job_id: string | null;
}

export type PublishCheck = { ok: true; unshared: number } | { ok: false; reason: string };

/**
 * Whether a showcase's photos can go on a public page: never when the client asked that photos of
 * their property not be posted, nor a photo that isn't a JPEG or PNG or isn't this job's. Photos
 * nobody has marked OK to share can go once someone says so (`unshared` says how many).
 */
export function publishCheck(jobId: string, picked: readonly string[], facts: readonly ShowcasePhotoFact[]): PublishCheck {
  let unshared = 0;
  for (const id of picked) {
    const fact = facts.find((f) => f.id === id);
    if (!fact || fact.job_id !== jobId) return { ok: false, reason: "One of the photos isn't on this job anymore. Pick the photos again." };
    if (fact.problem === "client_opt_out") return { ok: false, reason: CLIENT_OPT_OUT };
    if (fact.problem) return { ok: false, reason: CANT_SHARE[fact.problem as CantShare] ?? "One of the photos can't be shown." };
    if (!fact.shareable) unshared++;
  }
  return { ok: true, unshared };
}

/** "3 of these photos aren't marked OK to share": the question asked before they're published anyway. */
export const unsharedQuestion = (n: number, of: number) =>
  `${n === of ? (n === 1 ? "This photo isn't" : `These ${n} photos aren't`) : `${n} of these photos aren't`} marked OK to share, so the client may not have agreed to their photos being shown.`;

/** Before photos, then after, then the rest, each kept in the order picked. */
export function showcaseOrder<T extends { role: ShowcaseRole; sort: number }>(photos: readonly T[]): T[] {
  const rank: Record<ShowcaseRole, number> = { before: 0, after: 1, photo: 2 };
  return [...photos].sort((a, b) => rank[a.role] - rank[b.role] || a.sort - b.sort);
}

/** A caption for a post about it: the title, the write-up and the link, within what Instagram takes. */
export function showcaseCaption(title: string, description: string, url: string): string {
  const room = 2200 - url.length - title.length - 4;
  const words = description.trim().length > room ? `${description.trim().slice(0, Math.max(0, room - 1)).trimEnd()}…` : description.trim();
  return [title.trim(), words, url].filter(Boolean).join("\n\n");
}
