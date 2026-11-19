/**
 * One SOP: read it, confirm you've read it (answering its quiz first, if it has one), say whether it
 * helped or suggest a change, and for the office: see who's read it and what people said, edit,
 * copy, compare and restore versions, mark it reviewed or delete it. A job description also shows
 * how far each person with the job is through its training (the guides it links to).
 */
import { TRASH_DAYS } from "@jobly/core/drive";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Fragment, useEffect, useMemo, useRef, useState, type KeyboardEvent, type MouseEvent } from "react";
import { Link, useLocation, useNavigate, useParams } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Dialog } from "@/components/ui/Dialog";
import { Icon } from "@/components/ui/Icon";
import { Menu } from "@/components/ui/Menu";
import { BackLink, PageHeader } from "@/components/ui/PageHeader";
import { DetailSkeleton, Skeleton } from "@/components/ui/Skeleton";
import { ErrorState, PageError } from "@/components/ui/States";
import { Face } from "@/components/ui/Avatar";
import { Select } from "@/components/ui/Select";
import { ApiError, api, supabase, unwrap } from "@/lib/api";
import { formatDate, formatDateTime, timeAgo } from "@/lib/format";
import { hasContent, htmlToText, isAppPath, sanitizeHtml, withSections } from "@/lib/html";
import { can, hasRole, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { useCompanyRoles } from "../settings/roles";
import { GuideContents, goToSection, useCurrentSection } from "./GuideContents";
import { GuideCover } from "./GuideCover";
import { GuideFeedback } from "./GuideFeedback";
import { useGuidePictures } from "./pictures";
import { PictureViewer } from "./PictureViewer";
import { QuizDialog, type QuizQuestion } from "./QuizDialog";
import { ShareGuideDialog } from "./ShareGuideDialog";
import { VersionCompare } from "./VersionCompare";
import { guideQuery, mustRead, reviewDueAt, ROLE_LABELS, useIsEditor, useSopIndex, useTraining } from "./kbData";
import { msg, t } from "@/lib/i18n";

interface TeamMember { user_id: string; role: string; role_id: string | null; active: boolean; profile: { full_name: string; color: string | null; avatar_url?: string | null } | null }

export function SopPage() {
  const { pageId = "" } = useParams();
  const session = useSession();
  const { company, userId, roleId } = session;
  const editor = useIsEditor();
  // Owners and admins who edit guides decide who a guide is shared with outside the team.
  const sharer = editor && hasRole(session, "admin") && can(session, "kb_edit");
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [history, setHistory] = useState(false);
  const [quizzing, setQuizzing] = useState(false);
  const [sharing, setSharing] = useState(false);
  const [picture, setPicture] = useState<{ src: string; alt: string } | null>(null);
  const inlineContents = useRef<HTMLDetailsElement>(null);

  const page = useQuery(guideQuery(company.id, pageId));
  const team = useQuery({ queryKey: ["team", company.id], staleTime: 5 * 60_000, queryFn: () => api.get<TeamMember[]>("/team") });
  const roles = useCompanyRoles();
  const training = useTraining();
  const index = useSopIndex();
  // A job description (Settings → Roles): how far each person with the job is through its training.
  const jobRoles = (roles.data ?? []).filter((r) => r.guide_id === pageId);
  const trainingIds = [...new Set(jobRoles.flatMap((r) => training?.get(r.id) ?? []))];
  const trainingReads = useQuery({
    queryKey: ["kb", company.id, "training-reads", pageId, trainingIds],
    enabled: editor && trainingIds.length > 0,
    queryFn: async () => unwrap(await supabase().from("sop_acknowledgements").select("user_id, page_id, revision").eq("company_id", company.id).in("page_id", trainingIds)),
  });
  // The guides that link here, like a job's description linking each duty to how it's done.
  const linkedFrom = useQuery({
    queryKey: ["kb", company.id, "linked-from", pageId],
    enabled: Boolean(page.data),
    queryFn: async () => unwrap(await supabase().from("sop_pages").select("id, title").eq("company_id", company.id).neq("id", pageId).like("body_html", `%/kb/${pageId}%`).order("title").limit(50)),
  });
  const reads = useQuery({
    queryKey: ["kb", company.id, "reads", pageId, page.data?.revision],
    enabled: Boolean(page.data),
    queryFn: async () => unwrap(await supabase().from("sop_acknowledgements").select("user_id, acknowledged_at").eq("page_id", pageId).eq("revision", page.data!.revision).order("acknowledged_at")),
  });
  // Whether people outside the team can read it by its link, for the people who edit it: what they write shows there.
  const shared = useQuery({
    queryKey: ["kb", company.id, "shared", pageId],
    enabled: editor && Boolean(page.data),
    queryFn: async () => {
      const [share, people] = await Promise.all([
        supabase().from("sop_shares").select("access").eq("page_id", pageId).maybeSingle(),
        supabase().from("sop_share_people").select("id", { count: "exact", head: true }).eq("page_id", pageId),
      ]);
      return { anyone: unwrap(share)?.access === "anyone", people: people.count ?? 0 };
    },
  });
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["kb", company.id] });
  // Its quiz, as readers get it (questions and options, no answers): null when it has none.
  const quiz = useQuery({
    queryKey: ["kb", company.id, "quiz", pageId],
    enabled: Boolean(page.data),
    queryFn: async () => (unwrap(await supabase().rpc("guide_quiz", { p_page: pageId })) as unknown as QuizQuestion[] | null) ?? null,
  });
  const acknowledge = useMutation({
    meta: { success: t("Marked as read") },
    mutationFn: async () => unwrap(await supabase().rpc("acknowledge_guide", { p_page: pageId })),
    onSettled: refresh,
  });
  const remove = useMutation({
    mutationFn: async () => unwrap(await supabase().from("sop_pages").delete().eq("id", pageId)),
    onSuccess: () => {
      // Its cover photo goes to the Trash by itself (the database moves it).
      toast.success(t("Guide deleted"), page.data?.cover_path ? { description: t("Its cover photo is in the Trash for {days} days.", { days: TRASH_DAYS }) } : undefined);
      refresh();
      navigate("/kb", { replace: true });
    },
  });
  const review = useMutation({
    meta: { success: t("Marked as reviewed") },
    mutationFn: async () => unwrap(await supabase().from("sop_pages").update({ reviewed_at: new Date().toISOString() }).eq("id", pageId)),
    onSettled: refresh,
  });
  const pin = useMutation({
    meta: { success: (_: unknown, on: boolean) => (on ? t("Pinned to the top of the knowledge base") : t("Unpinned")) },
    mutationFn: async (on: boolean) => unwrap(await supabase().from("sop_pages").update({ pinned_at: on ? new Date().toISOString() : null }).eq("id", pageId)),
    onSettled: refresh,
  });
  const publish = useMutation({
    meta: { success: t("Guide published") },
    mutationFn: async () => unwrap(await supabase().from("sop_pages").update({ status: "published" }).eq("id", pageId)),
    onSettled: refresh,
  });
  const body = useMemo(() => {
    const html = sanitizeHtml(page.data?.body_html ?? "");
    return { empty: !hasContent(html), ...withSections(html) };
  }, [page.data?.body_html]);
  const sections = body.sections.length > 1 ? body.sections : [];
  const bodyHtml = useGuidePictures(body.html, true);
  const current = useCurrentSection(sections);
  // A link to a section (…/kb/id#mixing-ratio): go there once the guide is showing. A frame later, so the new screen's scroll to the top goes first.
  const { hash } = useLocation();
  useEffect(() => {
    if (hash.length < 2 || body.empty) return;
    const frame = requestAnimationFrame(() => document.getElementById(decodeURIComponent(hash.slice(1)))?.scrollIntoView());
    return () => cancelAnimationFrame(frame);
  }, [hash, body]);

  if (page.isPending) return <DetailSkeleton />;
  if (page.error || !page.data) return <PageError error={page.error ?? new ApiError(msg("This guide doesn't exist, or it was deleted."), 404)} onRetry={page.error ? () => page.refetch() : undefined} back={<BackLink to="/kb">{t("Knowledge base")}</BackLink>} />;
  const sop = page.data;
  const name = (id: string | null) => team.data?.find((m) => m.user_id === id)?.profile?.full_name ?? t("Team member");
  const readers = reads.data ?? [];
  const acknowledged = readers.some((r) => r.user_id === userId);
  // Who has to read it: required reading's audience, and everyone whose job's training includes it.
  const trainedBy = (roles.data ?? []).filter((r) => training?.get(r.id)?.includes(sop.id));
  const forThem = (m: TeamMember) => (sop.required && mustRead(sop, m)) || (m.role_id != null && trainedBy.some((r) => r.id === m.role_id));
  const audience = (team.data ?? []).filter((m) => m.active && forThem(m));
  const published = sop.status === "published";
  const askToRead = published && (sop.required || trainedBy.some((r) => r.id === roleId));
  // Who it's for, by team role (Settings → Roles) and by level; a deleted role isn't named.
  const forWhom = [...(roles.data ?? []).filter((r) => sop.audience_roles?.includes(r.id)).map((r) => r.name), ...(sop.audience ?? []).map((r) => ROLE_LABELS[r] ?? r)];
  const jobOf = jobRoles.map((r) => r.name);
  const trainingFor = jobOf.length ? [] : trainedBy.map((r) => r.name);
  const outstanding = audience.filter((m) => !readers.some((r) => r.user_id === m.user_id));
  const showReads = published && (sop.required || trainedBy.length > 0);
  const revisionOf = new Map((index.data?.pages ?? []).map((p) => [p.id, p.revision]));
  const trainees = (team.data ?? []).filter((m) => m.active && jobRoles.some((r) => r.id === m.role_id));
  const trainingDone = (user: string) => trainingIds.filter((id) => trainingReads.data?.some((a) => a.user_id === user && a.page_id === id && a.revision === revisionOf.get(id))).length;
  const showTraining = editor && trainingIds.length > 0;
  // On a review schedule: when it's next due, for the office.
  const due = reviewDueAt(sop);
  const reviewDue = due !== null && due <= new Date();
  // "#" beside a heading copies a link to it; the contents links just go there. A link to another
  // guide (or any screen in Jobly) opens here without reloading the app; ⌘-click still opens a tab.
  // A picture opens full screen, to zoom into on a phone.
  const openPicture = (target: EventTarget) => {
    const img = target instanceof HTMLImageElement ? target : null;
    if (!img?.currentSrc && !img?.getAttribute("src")) return false;
    setPicture({ src: img.currentSrc || img.src, alt: img.alt });
    return true;
  };
  const onArticleKeyDown = (e: KeyboardEvent) => {
    if ((e.key === "Enter" || e.key === " ") && openPicture(e.target)) e.preventDefault();
  };
  // Asked at the top of a guide and again at its end, where a phone finishes reading.
  const confirmRead = () => (quiz.data?.length ? setQuizzing(true) : acknowledge.mutate());
  const onArticleClick = (e: MouseEvent) => {
    if (openPicture(e.target)) return;
    const link = (e.target as Element).closest("a");
    const href = link?.getAttribute("href");
    if (!link || !href) return;
    if (href.startsWith("#")) {
      e.preventDefault();
      goToSection(decodeURIComponent(href.slice(1)), link.classList.contains("heading-anchor"));
    } else if (isAppPath(href) && !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey)) {
      e.preventDefault();
      navigate(href);
    }
  };

  return (
    <>
      <BackLink to={sop.category ? `/kb?category=${sop.category.id}` : "/kb"}>{sop.category?.name ?? t("Knowledge base")}</BackLink>
      <PageHeader
        title={sop.title}
        actions={
          <>
            {editor && reviewDue && <Button icon="check" loading={review.isPending} onClick={() => review.mutate()}>{t("Mark reviewed")}</Button>}
            {askToRead && (acknowledged ? (
              <span className="pill" data-tone="success" style={{ height: "var(--control)", padding: "0 14px" }}><Icon name="check" size={14} bold />{t("You've read this")}</span>
            ) : (
              <Button variant="primary" icon="check" loading={acknowledge.isPending} disabled={reads.isPending || quiz.isPending} onClick={confirmRead}>{t("I've read this")}</Button>
            ))}
            {editor && <Link className="btn" to={`/kb/${sop.id}/edit`}><Icon name="edit" size={16} />{t("Edit")}</Link>}
            <Menu
              label={t("More actions")}
              items={[
                { label: t("Print"), icon: "printer", onSelect: () => window.print() },
                { label: t("Share with a link"), icon: "share", onSelect: () => setSharing(true), hidden: !sharer },
                { label: t("Revision history"), icon: "history", onSelect: () => setHistory(true), hidden: !editor },
                { label: sop.pinned_at ? t("Unpin") : t("Pin to the top"), icon: sop.pinned_at ? "unpin" : "pushpin", onSelect: () => pin.mutate(!sop.pinned_at), hidden: !editor },
                { label: t("Make a copy"), icon: "copy", onSelect: () => navigate(`/kb/new?copy=${sop.id}`), hidden: !editor },
                { label: t("Publish"), icon: "send", onSelect: () => publish.mutate(), hidden: !editor || sop.status !== "draft" },
                { label: t("Mark reviewed"), icon: "check", onSelect: () => review.mutate(), hidden: !editor || !due || reviewDue },
                { separator: true, hidden: !editor },
                {
                  label: t("Delete guide"), icon: "trash", danger: true, hidden: !editor,
                  onSelect: async () => { if (await confirm({ title: t("Delete this guide?"), body: t("It's removed for everyone, along with its revision history and read receipts."), confirmLabel: t("Delete"), danger: true })) remove.mutate(); },
                },
              ]}
            />
          </>
        }
      />
      <div className="page-meta">
        {sop.status === "draft" && <span className="pill" data-tone="warning">{t("Draft · only the office can see this")}</span>}
        {editor && sop.pinned_at && <span className="pill"><Icon name="pushpin" size={12} />{t("Pinned")}</span>}
        {editor && shared.data?.anyone && <span className="pill"><Icon name="globe" size={12} />{t("Anyone with the link can read this")}</span>}
        {editor && shared.data && !shared.data.anyone && shared.data.people > 0 && (
          <span className="pill"><Icon name="link" size={12} />{t.plural(shared.data.people, { one: "Shared with {count} person outside the team", other: "Shared with {count} people outside the team" })}</span>
        )}
        {jobOf.length > 0 && <span className="pill" data-tone="info">{t("Job description for {roles}", { roles: jobOf.join(", ") })}</span>}
        {trainingFor.length > 0 && <span className="pill" data-tone="info">{t("Training for {roles}", { roles: trainingFor.join(", ") })}</span>}
        {sop.required && <span className="pill" data-tone="warning">{forWhom.length ? t("Required reading for {roles}", { roles: forWhom.join(", ") }) : t("Required reading")}</span>}
        {editor && reviewDue && <span className="pill" data-tone="warning">{t("Review due")}{sop.owner_id ? ` · ${name(sop.owner_id)}` : ""}</span>}
        <span className="muted small">
          {t("Revision {number}", { number: sop.revision })} · {sop.updated_by && team.data ? t("Updated {when} by {name}", { when: timeAgo(sop.revised_at), name: name(sop.updated_by) }) : t("Updated {when}", { when: timeAgo(sop.revised_at) })}
          {editor && due && !reviewDue && ` · ${sop.owner_id ? t("Next review {date} by {name}", { date: formatDate(due.toISOString()), name: name(sop.owner_id) }) : t("Next review {date}", { date: formatDate(due.toISOString()) })}`}
          {editor && quiz.data?.length ? ` · ${t.plural(quiz.data.length, { one: "Quiz: {count} question", other: "Quiz: {count} questions" })}` : ""}
        </span>
        {sop.tags.map((tag) => <Link key={tag} to={`/kb?q=${encodeURIComponent(tag)}`} className="tag no-print" title={t("Guides tagged with this")}>{tag}</Link>)}
        {linkedFrom.data && linkedFrom.data.length > 0 && (
          <span className="muted small no-print">{t("Linked from")} {linkedFrom.data.map((g, i) => <Fragment key={g.id}>{i > 0 && ", "}<Link to={`/kb/${g.id}`}>{g.title}</Link></Fragment>)}</span>
        )}
      </div>
      <div className="sop-reader">
        <div className="sop-layout">
          <div className="sop-main">
            {sop.cover_path && <GuideCover path={sop.cover_path} className="sop-cover no-print" />}
            {sections.length > 0 && (
              <details ref={inlineContents} className="card sop-toc-inline no-print">
                <summary>{t("On this page")}<span className="muted"> · {t.plural(sections.length, { one: "{count} section", other: "{count} sections" })}</span></summary>
                <GuideContents sections={sections} current={current} onPick={() => inlineContents.current?.removeAttribute("open")} />
              </details>
            )}
            <article className="card prose sop-body" onClick={onArticleClick} onKeyDown={onArticleKeyDown}>
              {body.empty ? <p className="muted">{t("This guide is empty.")}{editor && <> <Link to={`/kb/${sop.id}/edit`}>{t("Add content")}</Link></>}</p> : <div dangerouslySetInnerHTML={{ __html: bodyHtml }} />}
            </article>
            {askToRead && !body.empty && (
              <section className="card card-pad guide-done no-print" aria-label={t("Confirm you've read it")}>
                {acknowledged ? (
                  <span className="row" style={{ gap: 8, color: "var(--green-dark)" }}><Icon name="check" size={16} bold /><strong>{t("You've read this revision")}</strong></span>
                ) : (
                  <>
                    <span className="stack-sm" style={{ gap: 2 }}>
                      <strong>{t("Done reading?")}</strong>
                      <span className="muted small">{quiz.data?.length ? t.plural(quiz.data.length, { one: "Answer a question to confirm you've read it.", other: "Answer {count} questions to confirm you've read it." }) : t("Confirm you've read it, so the office knows.")}</span>
                    </span>
                    <Button variant="primary" icon="check" loading={acknowledge.isPending} disabled={reads.isPending || quiz.isPending} onClick={confirmRead}>{t("I've read this")}</Button>
                  </>
                )}
              </section>
            )}
            {published && !body.empty && <GuideFeedback page={sop} editor={editor} person={(id) => ({ name: name(id), photo: team.data?.find((m) => m.user_id === id)?.profile?.avatar_url })} />}
          </div>
          {(showReads || showTraining || sections.length > 0) && (
            <aside className="sop-aside no-print">
              {showTraining && (
                <div className="card card-pad stack-sm">
                  <div className="row-between"><strong className="small">{t("Training progress")}</strong><span className="muted small">{t.plural(trainingIds.length, { one: "{count} guide", other: "{count} guides" })}</span></div>
                  {!team.data || trainingReads.isPending ? <Skeleton height={28} /> : trainees.length === 0 ? <p className="muted small" style={{ margin: 0 }}>{jobOf.length === 1 ? t("No one has this role yet.") : t("No one has these roles yet.")}</p> : (
                    <div className="stack-sm" style={{ gap: 10 }}>
                      {trainees.map((m) => {
                        const done = trainingDone(m.user_id);
                        return (
                          <div key={m.user_id} className="stack-sm" style={{ gap: 4 }}>
                            <div className="row" style={{ gap: 8 }}>
                              <span className="avatar" style={{ width: 26, height: 26, fontSize: 11 }}><Face name={name(m.user_id)} photo={m.profile?.avatar_url} /></span>
                              <span className="grow small strong">{name(m.user_id)}</span>
                              <span className="muted small tabular">{t("{done} of {count}", { done, count: trainingIds.length })}</span>
                            </div>
                            <div className="progress"><span style={{ width: `${(done / trainingIds.length) * 100}%` }} /></div>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </div>
              )}
              {showReads && (
                <div className="card card-pad stack-sm">
                  <div className="row-between"><strong className="small">{t("Read this revision")}</strong><span className="muted small">{team.data ? t("{done} of {count}", { done: readers.length, count: audience.length }) : readers.length}</span></div>
                  {team.data && audience.length > 0 && <div className="progress"><span style={{ width: `${Math.min(100, (readers.length / audience.length) * 100)}%` }} /></div>}
                  {reads.isPending ? <Skeleton height={28} /> : readers.length === 0 ? <p className="muted small" style={{ margin: 0 }}>{t("No one has confirmed this revision yet.")}</p> : (
                    <div className="stack-sm" style={{ gap: 8 }}>
                      {readers.map((r) => (
                        <div key={r.user_id} className="row" style={{ gap: 8 }}>
                          <span className="avatar" style={{ width: 26, height: 26, fontSize: 11 }}><Face name={name(r.user_id)} photo={team.data?.find((m) => m.user_id === r.user_id)?.profile?.avatar_url} /></span>
                          <span className="grow small strong">{name(r.user_id)}</span>
                          <span className="muted small" title={formatDateTime(r.acknowledged_at)}>{formatDate(r.acknowledged_at)}</span>
                        </div>
                      ))}
                    </div>
                  )}
                  {editor && outstanding.length > 0 && (
                    <div className="stack-sm" style={{ gap: 6, marginTop: 6 }}>
                      <span className="muted small strong">{t("Still to read")}</span>
                      <div className="row wrap" style={{ gap: 6 }}>{outstanding.map((m) => <span key={m.user_id} className="chip">{m.profile?.full_name ?? t("Team member")}</span>)}</div>
                    </div>
                  )}
                </div>
              )}
              {sections.length > 0 && (
                <nav className="sop-toc" aria-label={t("On this page")}>
                  <strong className="small">{t("On this page")}</strong>
                  <GuideContents sections={sections} current={current} />
                </nav>
              )}
            </aside>
          )}
        </div>
      </div>
      {history && <HistoryDialog pageId={sop.id} current={sop.revision} names={name} onClose={() => setHistory(false)} />}
      {picture && <PictureViewer src={picture.src} alt={picture.alt} onClose={() => setPicture(null)} />}
      {sharing && <ShareGuideDialog pageId={sop.id} title={sop.title} onClose={() => setSharing(false)} />}
      {quizzing && quiz.data?.length && <QuizDialog pageId={sop.id} title={sop.title} questions={quiz.data} onClose={() => setQuizzing(false)} />}
    </>
  );
}

/**
 * Every saved version, newest first. Opening one shows what changed from the version before it, side
 * by side (or any other version, picked), or reads it as it was; an old one can be restored.
 */
function HistoryDialog({ pageId, current, names, onClose }: { pageId: string; current: number; names: (id: string | null) => string; onClose: () => void }) {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const [viewing, setViewing] = useState<number | null>(null);
  const [mode, setMode] = useState<"changes" | "read">("changes");
  const [against, setAgainst] = useState<number | null>(null);
  const revisions = useQuery({
    queryKey: ["kb", company.id, "revisions", pageId],
    queryFn: async () => unwrap(await supabase().from("sop_revisions").select("revision, title, body_html, edited_by, created_at").eq("page_id", pageId).order("revision", { ascending: false }).limit(100)),
  });
  const restore = useMutation({
    meta: { success: (_: unknown, r: number) => t("Revision {number} restored as a new revision", { number: r }) },
    mutationFn: async (revision: number) => {
      const r = revisions.data!.find((x) => x.revision === revision)!;
      unwrap(await supabase().from("sop_pages").update({ title: r.title, body: { type: "html", html: r.body_html }, body_html: r.body_html, body_text: htmlToText(r.body_html) }).eq("id", pageId));
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["kb", company.id] });
      onClose();
    },
  });
  const all = revisions.data ?? [];
  const open = (revision: number) => {
    const before = all.find((r) => r.revision < revision);
    setViewing(revision);
    setAgainst(before?.revision ?? all.find((r) => r.revision !== revision)?.revision ?? null);
    setMode(before ? "changes" : "read");
  };
  const shown = all.find((r) => r.revision === viewing);
  const base = all.find((r) => r.revision === against);
  const readHtml = useGuidePictures(useMemo(() => sanitizeHtml(shown?.body_html ?? ""), [shown?.body_html]));
  // Older on the left, newer on the right, whichever was picked first.
  const [older, newer] = shown && base ? (base.revision < shown.revision ? [base, shown] : [shown, base]) : [null, null];
  const label = (r: { revision: number; created_at: string }) => `${r.revision === current ? t("Revision {number} (current)", { number: r.revision }) : t("Revision {number}", { number: r.revision })} · ${formatDate(r.created_at)}`;
  const comparing = Boolean(shown && mode === "changes" && older && newer);

  return (
    <Dialog open onClose={onClose} title={shown ? t("Revision {number}", { number: shown.revision }) : t("Revision history")} description={shown ? `${shown.title} · ${t("{when} by {name}", { when: formatDateTime(shown.created_at), name: names(shown.edited_by) })}` : t("Every saved change is kept. Open one to see what changed, or to restore it.")} size={comparing ? "xl" : "lg"}>
      {shown ? (
        <div className="stack">
          <div className="row-between wrap" style={{ gap: 12 }}>
            <div className="segmented" role="group" aria-label={t("Show")}>
              <button type="button" aria-pressed={mode === "changes"} disabled={all.length < 2} onClick={() => setMode("changes")}>{t("Changes")}</button>
              <button type="button" aria-pressed={mode === "read"} onClick={() => setMode("read")}>{t("Read it")}</button>
            </div>
            {mode === "changes" && all.length > 1 && (
              <label className="row small" style={{ gap: 8 }}>
                <span className="muted" style={{ whiteSpace: "nowrap" }}>{t("Compared with")}</span>
                <Select className="select input-sm" value={against ?? ""} onChange={(e) => setAgainst(Number(e.target.value))}>
                  {all.filter((r) => r.revision !== shown.revision).map((r) => <option key={r.revision} value={r.revision}>{label(r)}</option>)}
                </Select>
              </label>
            )}
          </div>
          {comparing ? (
            <div className="diff-scroll">
              <VersionCompare before={{ label: label(older!), title: older!.title, html: older!.body_html }} after={{ label: label(newer!), title: newer!.title, html: newer!.body_html }} />
            </div>
          ) : (
            <div className="card card-pad prose" style={{ maxHeight: "55vh", overflowY: "auto", boxShadow: "none" }} dangerouslySetInnerHTML={{ __html: readHtml || "<p><em>Empty</em></p>" }} />
          )}
          <div className="form-actions">
            <Button variant="ghost" icon="arrowLeft" onClick={() => setViewing(null)}>{t("All revisions")}</Button>
            <span className="spacer" />
            {shown.revision !== current && <Button variant="primary" icon="undo" loading={restore.isPending} onClick={() => restore.mutate(shown.revision)}>{t("Restore revision {number}", { number: shown.revision })}</Button>}
          </div>
        </div>
      ) : (
        <div className="card" style={{ boxShadow: "none" }}>
          {revisions.isPending && [0, 1, 2].map((i) => <div key={i} className="card-row"><Skeleton height={20} /></div>)}
          {revisions.error && <ErrorState compact error={revisions.error} onRetry={() => revisions.refetch()} />}
          {all.map((r) => (
            <button key={r.revision} type="button" className="card-row" onClick={() => open(r.revision)}>
              <span className="badge">{r.revision}</span>
              <span className="grow stack-sm" style={{ gap: 2, minWidth: 0 }}>
                <strong className="ellipsis">{r.title}</strong>
                <span className="muted small">{formatDateTime(r.created_at)} · {names(r.edited_by)}</span>
              </span>
              {r.revision === current && <span className="pill" data-tone="success">{t("Current")}</span>}
              <Icon name="chevronRight" size={16} />
            </button>
          ))}
        </div>
      )}
    </Dialog>
  );
}
