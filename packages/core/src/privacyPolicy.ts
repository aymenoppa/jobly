/**
 * The business's privacy policy link (companies.settings.privacy_url, Settings → Company). The
 * pages Jobly serves for a business collect personal details (a booking form's name, phone,
 * email, address and photos; the Client Hub; a referral page), and a site that does should link
 * its privacy policy (California's Bus. & Prof. Code 22575(a): an operator "that collects
 * personally identifiable information ... shall conspicuously post its privacy policy on its Web
 * site"). The policy is the business's own to write and host; this is where its link goes, and it
 * shows in the footer of those pages once set.
 */

// The platform's URL (browsers, Node): core is built without DOM types.
declare const URL: new (input: string) => { href: string; protocol: string; hostname: string };

/** As long as a link can be. */
export const PRIVACY_URL_MAX = 500;
/** What the link is called in a page's footer. */
export const PRIVACY_LINK_LABEL = "Privacy policy";

/** A web address to link to: http or https, with a host, nothing else. Null when it isn't one. */
function webAddress(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const typed = value.trim();
  if (!typed || typed.length > PRIVACY_URL_MAX || /\s/.test(typed)) return null;
  try {
    const url = new URL(typed);
    return (url.protocol === "https:" || url.protocol === "http:") && url.hostname.includes(".") ? url.href : null;
  } catch {
    return null;
  }
}

/** The link saved for the company, or null when none is (or what's saved isn't a web address). */
export function privacyUrl(settings: Record<string, unknown> | null | undefined): string | null {
  return webAddress(settings?.privacy_url);
}

/**
 * What Settings → Company saves for what was typed: the link (with https:// put in front of a bare
 * "acme.com/privacy"), null for an empty box, or "invalid" when it isn't a web address.
 */
export function privacyUrlTyped(typed: string): string | null | "invalid" {
  const value = typed.trim();
  if (!value) return null;
  return webAddress(/^[a-z][a-z0-9+.-]*:/i.test(value) ? value : `https://${value}`) ?? "invalid";
}
