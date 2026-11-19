/**
 * What's said about showcases outside the Showcases tab, kept apart from the screens so it can be
 * tested: on a client's page (that they have one, and what turning off photos does to it), and on
 * a showcase that came down by itself (why).
 */

export interface ClientShowcase {
  id: string;
  title: string;
  status: string;
  unpublished_reason: string | null;
}

/** "1 showcase, published", "3 showcases, 2 published", "2 showcases, none published"; "" with none. */
export function clientShowcaseWords(showcases: readonly Pick<ClientShowcase, "status">[]): string {
  if (!showcases.length) return "";
  const live = showcases.filter((s) => s.status === "published").length;
  if (showcases.length === 1) return `1 showcase, ${live ? "published" : "not published"}`;
  return `${showcases.length} showcases, ${live || "none"} published`;
}

/**
 * Under a client's "Can be posted on social pages" switch: what the switch does to the showcases of
 * their jobs. On: turning it off takes the published ones down. Off already: they've been taken
 * down, and can't go back up while it's off.
 */
export function photoSwitchNote(showcases: readonly Pick<ClientShowcase, "status">[], optedOut: boolean): string | null {
  if (!showcases.length) return null;
  const live = showcases.filter((s) => s.status === "published").length;
  if (optedOut) return `Their ${showcases.length === 1 ? "showcase is" : "showcases are"} down and can't be published while this is off.`;
  if (!live) return null;
  return `Turning this off takes down ${live === 1 ? "their published showcase" : `their ${live} published showcases`}, pages anyone with the link can see.`;
}

/** "Taken down: the client asked that photos of their property not be posted", for a showcase that came down by itself; null otherwise. */
export function takenDownWords(s: Pick<ClientShowcase, "status" | "unpublished_reason">): string | null {
  return s.status === "unpublished" && s.unpublished_reason ? `Taken down: ${s.unpublished_reason}` : null;
}
