/**
 * Marketing → Showcases: every job showcase, published first, with its link to copy or open, Post
 * to Facebook or Instagram (Marketing → Social's composer, with its photos and a caption carrying
 * the link), and Edit, Publish or Unpublish (ShowcaseDialog). Showcases are made from a finished
 * job's page, or a finished visit's (?job=…&visit=… opens a new one here).
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { confirm } from "@/components/ui/Confirm";
import { Icon } from "@/components/ui/Icon";
import { Menu } from "@/components/ui/Menu";
import { TableSkeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { StatusPill } from "@/components/ui/StatusPill";
import { api, supabase, unwrap } from "@/lib/api";
import { copyText } from "@/lib/clipboard";
import { formatDate } from "@/lib/format";
import { useSession } from "@/lib/session";
import { ShowcaseDialog, showcaseLink, socialPostPath } from "./ShowcaseDialog";
import { takenDownWords } from "./showcaseWords";

type Open = { jobId: string; visitId?: string | null; showcaseId?: string | null };

export function Showcases() {
  const session = useSession();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [params, setParams] = useSearchParams();
  const [open, setOpen] = useState<Open | null>(null);
  // Opened from a finished visit: a new showcase of its job, its photos first.
  useEffect(() => {
    const job = params.get("job");
    if (!job) return;
    setOpen({ jobId: job, visitId: params.get("visit") });
    setParams({ tab: "showcases" }, { replace: true });
  }, [params, setParams]);

  const list = useQuery({
    queryKey: ["showcases", session.company.id],
    queryFn: async () =>
      unwrap(
        await supabase()
          .from("showcases")
          .select("id, job_id, visit_id, title, description, status, token, published_at, unpublished_reason, created_at, job:jobs(number, title), photos:showcase_photos(attachment_id, sort)")
          .eq("company_id", session.company.id)
          .order("created_at", { ascending: false })
          .limit(200),
      ),
  });
  const refresh = () => void queryClient.invalidateQueries({ queryKey: ["showcases", session.company.id] });
  const unpublish = useMutation({ meta: { success: "Unpublished" }, mutationFn: (id: string) => api.post(`/showcases/${id}/unpublish`), onSuccess: refresh });
  const remove = useMutation({
    meta: { success: "Showcase deleted" },
    mutationFn: async (s: { id: string; status: string }) => {
      if (s.status === "published") await api.post(`/showcases/${s.id}/unpublish`);
      unwrap(await supabase().from("showcases").delete().eq("id", s.id));
    },
    onSuccess: refresh,
  });

  const rows = [...(list.data ?? [])].sort((a, b) => Number(b.status === "published") - Number(a.status === "published"));
  return (
    <div className="stack">
      <span className="muted small">
        A finished job's before and after photos and a few lines about the work, on a page you can share. Make one from a finished job's page (its menu) or a finished visit. The client's name and address are never shown.
      </span>
      {list.isPending ? <TableSkeleton columns={3} rows={3} /> : list.error ? (
        <div className="card"><ErrorState error={list.error} onRetry={() => list.refetch()} /></div>
      ) : !rows.length ? (
        <div className="card"><EmptyState icon="image" title="No showcases yet" action={<Link className="btn" to="/jobs">Go to jobs</Link>}>Open a finished job and pick Make a showcase.</EmptyState></div>
      ) : (
        <div className="card">
          {rows.map((s) => {
            const job = s.job as { number: number; title: string } | null;
            const photoIds = [...(s.photos ?? [])].sort((a, b) => a.sort - b.sort).map((p) => p.attachment_id);
            const live = s.status === "published";
            return (
              <div key={s.id} className="card-row">
                <button type="button" className="grow" style={{ all: "unset", cursor: "pointer", minWidth: 0, flex: 1 }} onClick={() => setOpen({ jobId: s.job_id, showcaseId: s.id })}>
                  <strong className="ellipsis" style={{ display: "block" }}>{s.title}</strong>
                  <span className="muted small ellipsis" style={{ display: "block" }}>
                    {job ? `Job #${job.number} · ${job.title}` : "Job"} · {photoIds.length} {photoIds.length === 1 ? "photo" : "photos"}{live && s.published_at ? ` · Published ${formatDate(s.published_at)}` : ""}
                  </span>
                  {/* It came down by itself: said here, as on the bell, so nobody wonders where the page went. */}
                  {takenDownWords(s) && <span className="small" style={{ display: "block", color: "var(--warning)", fontWeight: 600 }}>{takenDownWords(s)}</span>}
                </button>
                <StatusPill label={live ? "Published" : takenDownWords(s) ? "Taken down" : s.status === "unpublished" ? "Unpublished" : "Draft"} tone={live ? "good" : "muted"} />
                <Menu
                  triggerClassName="btn btn-sm btn-ghost btn-icon"
                  items={[
                    { label: "Copy link", icon: "copy", hidden: !live, onSelect: () => copyText(showcaseLink(s.token), "Link copied") },
                    { label: "Open page", icon: "external", hidden: !live, onSelect: () => window.open(showcaseLink(s.token), "_blank", "noopener") },
                    { label: "Post to Facebook or Instagram", icon: "share", hidden: !live || !photoIds.length, onSelect: () => navigate(socialPostPath(s, photoIds)) },
                    { label: live ? "View" : "Edit", icon: live ? "eye" : "edit", onSelect: () => setOpen({ jobId: s.job_id, showcaseId: s.id }) },
                    { label: "Unpublish", icon: "x", hidden: !live, onSelect: () => unpublish.mutate(s.id) },
                    { separator: true },
                    { label: "Delete", icon: "trash", danger: true, onSelect: async () => (await confirm({ title: "Delete this showcase?", body: live ? "Its link stops working. The job's photos aren't touched." : "The job's photos aren't touched.", confirmLabel: "Delete", danger: true })) && remove.mutate(s) },
                  ]}
                />
              </div>
            );
          })}
        </div>
      )}
      {open && <ShowcaseDialog key={open.showcaseId ?? open.jobId} jobId={open.jobId} visitId={open.visitId} showcaseId={open.showcaseId} onClose={() => { setOpen(null); refresh(); }} />}
      <p className="muted small" style={{ margin: 0 }}><Icon name="info" size={12} /> Posting to Facebook or Instagram shares the photos as taken, without their drawings.</p>
    </div>
  );
}
