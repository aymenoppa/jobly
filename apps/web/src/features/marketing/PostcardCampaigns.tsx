/**
 * Marketing → Campaigns' postcards (PostcardPage): New postcard, and each campaign with where it's
 * at, test campaigns marked as such.
 */
import { POSTCARD_SIZE_INFO, type PostcardSize } from "@jobly/core/postcards";
import { useMutation, useQuery } from "@tanstack/react-query";
import { Link, useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { FormError } from "@/components/ui/Field";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { EntityStatus } from "@/components/ui/StatusPill";
import { supabase, unwrap } from "@/lib/api";
import { formatDate } from "@/lib/format";
import { useSession } from "@/lib/session";

/** A new postcard's message, to change. */
export const POSTCARD_STARTER = "Hi {{client.first_name}},\n\nOur schedule fills up fast this time of year. Book your visit today and we'll get you on the calendar.\n\n{{link}}\n\n{{company.name}}\n{{company.phone}}";

export function PostcardCampaigns() {
  const session = useSession();
  const navigate = useNavigate();
  const list = useQuery({
    queryKey: ["postcard-campaigns", session.company.id],
    refetchInterval: (q) => ((q.state.data as Array<{ status: string }> | undefined)?.some((c) => c.status === "sending") ? 5000 : false),
    queryFn: async () =>
      unwrap(
        await supabase()
          .from("postcard_campaigns")
          .select("id, name, size, status, mode, recipients_count, made_count, failed_count, finished_at, created_at")
          .eq("company_id", session.company.id)
          .order("created_at", { ascending: false })
          .limit(200),
      ),
  });
  const create = useMutation({
    meta: { inline: true },
    mutationFn: async () =>
      unwrap(
        await supabase()
          .from("postcard_campaigns")
          .insert({ company_id: session.company.id, name: `Postcard ${new Date().toLocaleDateString("en-US", { month: "short", day: "numeric" })}`, message: POSTCARD_STARTER, audience: { statuses: ["active"] } })
          .select("id")
          .single(),
      ),
    onSuccess: (row) => navigate(`/marketing/postcards/${row.id}`),
  });
  type Row = NonNullable<typeof list.data>[number];
  const when = (c: Row) => {
    const made = c.mode === "live" ? "mailed" : "made in test mode";
    if (c.status === "draft") return `Draft · ${POSTCARD_SIZE_INFO[c.size as PostcardSize]?.label ?? c.size}`;
    if (c.status === "sending") return `${c.made_count.toLocaleString("en-US")} of ${c.recipients_count.toLocaleString("en-US")} ${made}…`;
    return `${c.made_count.toLocaleString("en-US")} ${made}${c.failed_count ? `, ${c.failed_count} failed` : ""}${c.finished_at ? ` · ${formatDate(c.finished_at)}` : ""}`;
  };
  return (
    <section className="stack" aria-labelledby="postcard-campaigns">
      <div className="row-between">
        <h2 id="postcard-campaigns" className="section-title">Postcards</h2>
        <Button icon="plus" loading={create.isPending} onClick={() => create.mutate()}>New postcard</Button>
      </div>
      <FormError error={create.error} />
      {list.isPending ? (
        <Skeleton height={64} />
      ) : list.error ? (
        <div className="card"><ErrorState compact error={list.error} onRetry={() => list.refetch()} /></div>
      ) : !list.data.length ? (
        <div className="card"><EmptyState icon="mail" title="No postcards yet">Mail a postcard with one of your job photos to the clients you pick, printed and mailed by Lob.</EmptyState></div>
      ) : (
        <div className="card">
          {list.data.map((c) => (
            <Link key={c.id} to={`/marketing/postcards/${c.id}`} className="card-row" style={{ color: "inherit" }}>
              <div className="grow" style={{ minWidth: 0 }}>
                <strong className="ellipsis" style={{ display: "block" }}>{c.name}</strong>
                <span className="muted small ellipsis" style={{ display: "block" }}>{when(c)}</span>
              </div>
              {c.mode === "test" && c.status !== "draft" && <span className="chip">Test</span>}
              <EntityStatus kind="campaign" status={c.status} />
            </Link>
          ))}
        </div>
      )}
    </section>
  );
}
