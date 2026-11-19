/**
 * The business's privacy policy link (Settings → Company), in the footer of the pages its clients
 * and the public use: the booking form, the Client Hub, a showcase, a referral page and the
 * unsubscribe page. Nothing when the business has set none.
 */
import { PRIVACY_LINK_LABEL } from "@jobly/core/privacyPolicy";

export function PrivacyLink({ url, className }: { url: string | null | undefined; className?: string }) {
  if (!url) return null;
  return <a href={url} target="_blank" rel="noopener noreferrer" className={className}>{PRIVACY_LINK_LABEL}</a>;
}

/** A footer line of its own, for the pages that end with their card. */
export function PrivacyFooter({ url }: { url: string | null | undefined }) {
  if (!url) return null;
  return (
    <footer className="muted small" style={{ textAlign: "center", marginTop: 16 }}>
      <PrivacyLink url={url} />
    </footer>
  );
}
