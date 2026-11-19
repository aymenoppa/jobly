/**
 * Who a postcard draft goes to, in full, before anything is spent: every client who gets a card
 * with the address it's mailed to, and everyone left out with why (public.postcard_audience, read a
 * page at a time). It scrolls, and downloads as a spreadsheet. One card goes to each address, and
 * the list says how the client is chosen when two share one.
 */
import { audienceKeys, type CampaignAudience } from "@jobly/core/campaigns";
import { ONE_PER_ADDRESS } from "@jobly/core/postcards";
import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { supabase } from "@/lib/api";
import { downloadCsv, toCsv } from "@/lib/csv";
import { everyRow, type PagedQuery } from "@/lib/paging";
import { useSession } from "@/lib/session";
import { audienceAddress, audienceCsvRows, leftOutWords, type AudienceRow } from "./postcardForm";

export function PostcardAudienceDialog({ name, audience, onClose }: { name: string; audience: CampaignAudience; onClose: () => void }) {
  const session = useSession();
  const [show, setShow] = useState<"in" | "out">("in");
  const list = useQuery({
    queryKey: ["postcard-audience-list", session.company.id, JSON.stringify(audienceKeys(audience))],
    queryFn: () =>
      everyRow<AudienceRow>(() => supabase().rpc("postcard_audience", { p_company: session.company.id, p_audience: audienceKeys(audience) as never }) as unknown as PagedQuery<AudienceRow>, { order: "display_name", key: "client_id" }),
  });
  const rows = list.data ?? [];
  const getting = rows.filter((r) => !r.left_out);
  const left = rows.filter((r) => r.left_out);
  const shown = show === "in" ? getting : left;
  const download = () => {
    const sheet = audienceCsvRows(rows);
    downloadCsv(`${name.replace(/[^\w -]+/g, "").trim() || "postcards"} - who gets a card.csv`, toCsv(sheet.rows, sheet.columns));
  };
  return (
    <Dialog open onClose={onClose} title="Who gets a card" size="lg">
      {list.isPending ? (
        <Skeleton height={240} />
      ) : list.error ? (
        <ErrorState compact error={list.error} onRetry={() => list.refetch()} />
      ) : (
        <div className="stack">
          <div className="row-between wrap" style={{ gap: 8 }}>
            <div className="segmented" role="group" aria-label="Show">
              <button type="button" aria-pressed={show === "in"} onClick={() => setShow("in")}>Getting a card ({getting.length.toLocaleString("en-US")})</button>
              <button type="button" aria-pressed={show === "out"} onClick={() => setShow("out")}>Left out ({left.length.toLocaleString("en-US")})</button>
            </div>
            <Button icon="download" onClick={download} disabled={!rows.length}>Download the list</Button>
          </div>
          {!shown.length ? (
            <EmptyState icon="mail" title={show === "in" ? "No one gets a card yet" : "No one is left out"} />
          ) : (
            <div style={{ maxHeight: "55vh", overflowY: "auto", border: "1px solid var(--divider)", borderRadius: 8 }} role="list" aria-label={show === "in" ? "Clients getting a card" : "Clients left out"}>
              {shown.map((r) => (
                <div key={r.client_id} className="card-row" role="listitem">
                  <div className="grow" style={{ minWidth: 0 }}>
                    <Link to={`/clients/${r.client_id}`} target="_blank" rel="noreferrer" className="ellipsis" style={{ display: "block", fontWeight: 600 }}>{r.display_name}</Link>
                    <span className="muted small" style={{ display: "block", overflowWrap: "anywhere" }}>{audienceAddress(r) || "No address"}</span>
                  </div>
                  {r.left_out && <span className="small">{leftOutWords(r.left_out)}</span>}
                </div>
              ))}
            </div>
          )}
          <span className="muted small">Each card goes to the client's billing address, or their first property's when that one can't be mailed to. {ONE_PER_ADDRESS} A wrong address is fixed on the client's page.</span>
        </div>
      )}
    </Dialog>
  );
}
