/**
 * A job showcase (/s/:token): a business's before and after photos of a finished job and its
 * write-up, in the business's logo and colour, with Get a quote to its booking form when it has one.
 * Never the client's name or address; the town only when the business chose to show it. An
 * unpublished one says it isn't available. No account needed.
 */
import { useQuery } from "@tanstack/react-query";
import { useEffect } from "react";
import { useParams } from "react-router-dom";
import { Icon } from "@/components/ui/Icon";
import { PrivacyFooter } from "@/components/ui/PrivacyLink";
import { Skeleton } from "@/components/ui/Skeleton";
import { initials, inkOn } from "@/features/documents/words";
import { publicFetch } from "@/lib/publicApi";

interface ShowcaseView {
  company: { name: string; phone: string | null; website: string | null; logo: string | null; color: string | null; privacy_url?: string | null };
  title: string;
  description: string;
  town: string | null;
  published_at: string;
  photos: Array<{ role: "before" | "after" | "photo"; src: string }>;
  book_url: string | null;
}

export function ShowcasePage() {
  const { token = "" } = useParams();
  const view = useQuery({ queryKey: ["showcase", token], retry: false, queryFn: () => publicFetch<ShowcaseView>(`/public/showcases/${token}`) });
  const d = view.data;
  useEffect(() => {
    document.title = d ? `${d.title} · ${d.company.name}` : "Showcase";
  }, [d]);
  const brand = d?.company.color || "#3b7d23";
  const group = (role: ShowcaseView["photos"][number]["role"]) => d?.photos.filter((p) => p.role === role) ?? [];
  const sections = d ? ([["Before", group("before")], ["After", group("after")], [group("before").length || group("after").length ? "More photos" : null, group("photo")]] as const) : [];

  return (
    <div className="public-page" style={{ ["--brand" as string]: brand, ["--on-brand" as string]: inkOn(brand) }}>
      <div className="public-wrap" style={{ maxWidth: 860 }}>
        {view.isPending && <div className="card card-pad stack-sm"><Skeleton width="60%" height={26} /><Skeleton width="80%" /><Skeleton height={320} radius={8} /></div>}
        {view.error && (
          <div className="card"><div className="empty-state error-state"><span className="empty-icon"><Icon name="image" size={24} /></span><h3>This showcase isn't available</h3><p>{(view.error as { status?: number }).status === 404 ? "It may have been taken down by the business." : (view.error as Error).message}</p></div></div>
        )}
        {d && (
          <div className="stack-lg">
            <header className="public-brand">
              {d.company.logo ? <img className="logo" src={d.company.logo} alt="" /> : <span className="tile" aria-hidden="true" style={{ background: "var(--brand)", color: "var(--on-brand)" }}>{initials(d.company.name)}</span>}
              <div><strong>{d.company.name}</strong>{d.company.phone && <div className="muted text-sm"><a href={`tel:${d.company.phone}`}>{d.company.phone}</a></div>}</div>
            </header>
            <section className="card card-pad stack" style={{ borderTop: "4px solid var(--brand)" }}>
              <div className="stack-sm">
                <h1 style={{ fontSize: 26, fontWeight: 800, letterSpacing: "var(--tracking-display)", margin: 0 }}>{d.title}</h1>
                {d.town && <span className="muted row" style={{ gap: 6 }}><Icon name="pin" size={14} />{d.town}</span>}
              </div>
              {d.description && <p className="pre-wrap" style={{ margin: 0, fontSize: 16, lineHeight: 1.55 }}>{d.description}</p>}
              {d.book_url && (
                <a className="btn btn-lg" href={d.book_url} style={{ justifySelf: "start", background: "var(--brand)", color: "var(--on-brand)", borderColor: "var(--brand)" }}>
                  <Icon name="quote" size={18} />Get a quote
                </a>
              )}
            </section>
            {sections.map(([label, photos]) =>
              photos.length ? (
                <section key={label ?? "photos"} className="stack-sm" aria-label={label ?? "Photos"}>
                  {label && <h2 className="section-title">{label}</h2>}
                  <div style={{ display: "grid", gap: 12, gridTemplateColumns: "repeat(auto-fit, minmax(min(100%, 320px), 1fr))" }}>
                    {photos.map((p) => <img key={p.src} src={p.src} alt={label ? `${label} photo` : "Photo of the work"} loading="lazy" style={{ width: "100%", borderRadius: 8, display: "block", background: "var(--fill-2)" }} />)}
                  </div>
                </section>
              ) : null,
            )}
            {d.book_url && (
              <div className="card card-pad row-between wrap" style={{ gap: 12 }}>
                <strong>Want work like this at your place?</strong>
                <a className="btn" href={d.book_url} style={{ background: "var(--brand)", color: "var(--on-brand)", borderColor: "var(--brand)" }}>Get a quote</a>
              </div>
            )}
            <PrivacyFooter url={d.company.privacy_url} />
          </div>
        )}
      </div>
    </div>
  );
}
