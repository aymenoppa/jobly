/**
 * A showcase link's preview. Facebook, Nextdoor, a phone's Messages and the like don't run the web
 * app: they read the page's head. So /s/<token> is answered with the app's page plus Open Graph and
 * Twitter card tags for that showcase (its title, the start of its write-up, its first photo), and a
 * shared link shows the job instead of a bare address.
 *
 *   Only published   The tags come from what the public page itself is given
 *                    (GET /api/public/showcases/<token>), so a showcase that isn't published, or
 *                    whose company has Marketing uninstalled, gets the plain page and no tags.
 *   Escaped          The title and write-up are the office's words, put into attributes: every
 *                    character that could end one is escaped.
 *   Not for search   The page is marked noindex, as its data and photos already are: a preview is
 *                    for someone who was sent the link.
 *   Kept a minute    A link shared in a busy group is fetched many times at once; the tags are kept
 *                    for a minute, so that's one read. Unpublishing shows within the minute (the
 *                    page itself, and its photos, stop at once). The page is still sent no-cache,
 *                    as the app's page always is, so an update is never held back by it.
 */
import type { Context, MiddlewareHandler } from "hono";

export interface ShowcasePreview {
  title: string;
  description: string;
  /** The business's name. */
  company: string;
  /** The first photo's address, whole (https://…), or null without one. */
  image: string | null;
  /** The showcase's own address. */
  url: string;
}

const escapeAttribute = (value: string) => value.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]!);

/** One line, at most `max` characters, ending on a word. */
function brief(text: string, max: number): string {
  const line = text.replace(/\s+/g, " ").trim();
  if (line.length <= max) return line;
  const cut = line.slice(0, max - 1);
  return `${cut.slice(0, Math.max(cut.lastIndexOf(" "), max - 40)).trimEnd()}…`;
}

/** What the public page's data says, as a preview. `base` is this server's public address. */
export function previewOf(page: unknown, base: string, token: string): ShowcasePreview | null {
  const p = page as { title?: unknown; description?: unknown; company?: { name?: unknown }; photos?: Array<{ src?: unknown }> } | null;
  if (!p || typeof p.title !== "string" || !p.title.trim()) return null;
  const origin = base.replace(/\/$/, "");
  const first = p.photos?.find((photo) => typeof photo.src === "string" && photo.src.startsWith("/api/public/showcases/"))?.src as string | undefined;
  const company = typeof p.company?.name === "string" ? p.company.name : "";
  return {
    title: brief(p.title, 120),
    description: brief(typeof p.description === "string" && p.description.trim() ? p.description : company ? `A job by ${company}.` : "", 200),
    company,
    image: first ? `${origin}${first}` : null,
    url: `${origin}/s/${token}`,
  };
}

/** The tags, as HTML for the page's head. */
export function previewTags(preview: ShowcasePreview): string {
  const meta = (attribute: "property" | "name", key: string, value: string) => (value ? `<meta ${attribute}="${key}" content="${escapeAttribute(value)}">` : "");
  return [
    '<meta name="robots" content="noindex">',
    meta("property", "og:type", "article"),
    meta("property", "og:title", preview.title),
    meta("property", "og:description", preview.description),
    meta("property", "og:url", preview.url),
    meta("property", "og:site_name", preview.company),
    meta("property", "og:image", preview.image ?? ""),
    meta("name", "description", preview.description),
    meta("name", "twitter:card", preview.image ? "summary_large_image" : "summary"),
    meta("name", "twitter:title", preview.title),
    meta("name", "twitter:description", preview.description),
    meta("name", "twitter:image", preview.image ?? ""),
  ]
    .filter(Boolean)
    .join("");
}

/** The app's page with the tags at the end of its head. A page with no head is left as it is. */
export function withPreview(indexHtml: string, tags: string): string {
  const at = indexHtml.search(/<\/head>/i);
  return at === -1 ? indexHtml : `${indexHtml.slice(0, at)}${tags}${indexHtml.slice(at)}`;
}

const TOKEN = /^[0-9a-f]{32}$/;
const KEEP_MS = 60_000;
const KEEP_MOST = 500;

/**
 * Answers /s/:token with the app's page and the showcase's tags. `lookup` reads the showcase as a
 * visitor would (null when it isn't there to be seen); anything but a published showcase, and any
 * trouble reading one, goes on to the plain page.
 */
export function showcasePage<C extends Context>(options: { indexHtml: string | null; lookup: (token: string, c: C) => Promise<ShowcasePreview | null>; now?: () => number }): MiddlewareHandler {
  const kept = new Map<string, { at: number; html: string | null }>();
  const now = options.now ?? Date.now;
  return async (c, next) => {
    const token = c.req.param("token") ?? "";
    if (!options.indexHtml || !TOKEN.test(token)) return next();
    let found = kept.get(token);
    if (!found || now() - found.at > KEEP_MS) {
      const preview = await options.lookup(token, c as unknown as C).catch(() => null);
      found = { at: now(), html: preview ? withPreview(options.indexHtml, previewTags(preview)) : null };
      if (kept.size >= KEEP_MOST) kept.clear();
      kept.set(token, found);
    }
    if (!found.html) return next();
    return c.html(found.html, 200, { "Cache-Control": "no-cache", "X-Robots-Tag": "noindex" });
  };
}
