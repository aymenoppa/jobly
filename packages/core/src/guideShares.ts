/**
 * Sharing a guide by link with people outside the team
 * (supabase/migrations/20261117000200_guide_sharing.sql): only the people the business adds by email
 * address, each proving the address with a code sent to it, or anyone who has the link. Shared by
 * the API (apps/api/src/routes/guideShares.ts) and the web app: the link, the emails, and which of a
 * guide's pictures its shared page may show.
 */
import { emailKey } from "./email";

export const GUIDE_SHARE_ACCESS = ["restricted", "anyone"] as const;
export type GuideShareAccess = (typeof GUIDE_SHARE_ACCESS)[number];
/** As a shared document names them. */
export const ACCESS_LABELS: Record<GuideShareAccess, string> = { restricted: "Restricted", anyone: "Anyone with the link" };

/** The most people a guide is shared with by address (private.sop_share_person_guard). */
export const MAX_SHARE_PEOPLE = 50;
/** The most addresses added in one go. */
export const MAX_SHARE_ADD = 20;
/** How long an emailed code works, and how many tries it gets. */
export const GUIDE_CODE_MINUTES = 15;
export const GUIDE_CODE_TRIES = 5;
/** How long this browser stays let in once a code was right, before it asks for another. */
export const GUIDE_KEY_DAYS = 30;

/** The shared page's address. */
export const guideShareUrl = (base: string, token: string) => `${base.replace(/\/$/, "")}/g/${token}`;

/**
 * Addresses typed or pasted into Add people (commas, semicolons, spaces or lines between them, or
 * "Name <address>" as a mail program copies them), each once in one spelling, and those that aren't
 * whole addresses, as typed.
 */
export function readAddresses(input: string): { emails: string[]; bad: string[] } {
  const emails = new Set<string>();
  const bad: string[] = [];
  for (const part of input.split(/[\s,;]+/)) {
    const typed = part.replace(/^[<("']+|[>)"'.]+$/g, "");
    if (!typed) continue;
    const key = emailKey(typed);
    // A name beside its address ("Dana Reyes <dana@…>") isn't a mistake; only something with an @ that isn't one is.
    if (key) emails.add(key);
    else if (typed.includes("@")) bad.push(typed);
  }
  return { emails: [...emails], bad };
}

/**
 * A guide's title or a person's name as one line of an email. Whoever edits guides writes the title,
 * and a line break in it would start a paragraph of its own in the email: a web address alone on a
 * line there is shown as a button.
 */
const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

/** The email a person gets when a guide is shared with them. */
export function guideInviteEmail(m: { companyName: string; title: string; url: string; by?: string | null; access: GuideShareAccess }): { subject: string; text: string } {
  const by = oneLine(m.by ?? "");
  const title = oneLine(m.title);
  const who = by ? `${by} at ${m.companyName}` : m.companyName;
  return {
    subject: `${m.companyName} shared a guide with you: ${title}`,
    text: [
      `${who} shared a guide with you: ${title}.`,
      m.url,
      m.access === "restricted"
        ? "When you open it, you'll be asked for this email address and sent a code, so only the people it was shared with can read it."
        : null,
    ].filter(Boolean).join("\n\n"),
  };
}

/** The email with the code that proves an address. */
export function guideCodeEmail(m: { companyName: string; title: string; code: string }): { subject: string; text: string } {
  const title = oneLine(m.title);
  return {
    subject: `Your code to open ${title}`,
    text: `Here's your code to open "${title}" from ${m.companyName}:\n\n${m.code}\n\nIt runs out in ${GUIDE_CODE_MINUTES} minutes. If you didn't ask for it, ignore this email.\n\nThanks,\n${m.companyName}`,
  };
}

/**
 * The stored pictures a guide's shared page may show: the ones its HTML names in its own company's
 * kb/ folder (as private.guide_picture_paths reads them), and its cover. Nothing else in the files
 * bucket is ever served for a guide, whatever its HTML says.
 */
export function sharedPictures(companyId: string, html: string, coverPath?: string | null): string[] {
  const own = new RegExp(`^${companyId}/kb/[0-9A-Za-z_-]+\\.[0-9a-z]+$`);
  const named = [...html.matchAll(/data-path="([^"]+)"/g)].map((m) => m[1]!);
  return [...new Set([...(coverPath ? [coverPath] : []), ...named])].filter((path) => own.test(path));
}

/** A stored picture's name on the shared page: the last part of its path. */
export const pictureName = (path: string) => path.slice(path.lastIndexOf("/") + 1);
