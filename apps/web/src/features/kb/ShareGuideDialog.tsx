/**
 * Share a guide with people outside the team, by link (apps/api/src/routes/guideShares.ts): only
 * the people added here by email address, who each prove the address with a code sent to it, or
 * anyone who has the link. For owners and admins who edit guides. Changes save as they're made.
 */
import { ACCESS_LABELS, GUIDE_SHARE_ACCESS, MAX_SHARE_ADD, MAX_SHARE_PEOPLE, readAddresses, type GuideShareAccess } from "@jobly/core/guideShares";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { Button, useJustDone } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Dialog } from "@/components/ui/Dialog";
import { FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { Menu } from "@/components/ui/Menu";
import { Skeleton } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/States";
import { api } from "@/lib/api";
import { ApiError } from "@/lib/errors";
import { copyText } from "@/lib/clipboard";
import { timeAgo } from "@/lib/format";
import { useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { addedNote } from "./shareWords";

export interface SharedPerson { id: string; email: string; created_at: string; last_opened_at: string | null }
export interface GuideShare {
  access: GuideShareAccess;
  /** The guide's page for people outside the team. */
  url: string;
  /** A draft's link says the guide isn't available. */
  published: boolean;
  /** Without email, nobody can be sent a code. */
  email_ready: boolean;
  people: SharedPerson[];
}
interface Added extends GuideShare { added: string[]; emailed: string[]; not_emailed: string[]; problem: string | null }

const WHO: Record<GuideShareAccess, string> = {
  restricted: "Only people with access can open the link. Someone you add types their email address and gets a code there.",
  anyone: "Anyone who has the link can read this guide, with no code or sign-in. Keep prices and anything private out of it.",
};

export function ShareGuideDialog({ pageId, title, onClose }: { pageId: string; title: string; onClose: () => void }) {
  const { company } = useSession();
  const queryClient = useQueryClient();
  const key = ["kb", company.id, "share", pageId];
  // Opening Share gives the guide its link, for nobody outside the team until someone is added.
  const share = useQuery({ queryKey: key, queryFn: () => api.post<GuideShare>(`/guides/${pageId}/share`), staleTime: 0 });
  const keep = (state: GuideShare) => {
    const { access, url, published, email_ready, people } = state;
    queryClient.setQueryData<GuideShare>(key, { access, url, published, email_ready, people });
    // The guide's own page, and its card in the knowledge base, say that it's shared.
    queryClient.invalidateQueries({ queryKey: ["kb", company.id, "shared"] });
  };
  const [typed, setTyped] = useState("");

  const setAccess = useMutation({
    mutationFn: (access: GuideShareAccess) => api.patch<GuideShare>(`/guides/${pageId}/share`, { access }),
    onSuccess: keep,
    meta: { success: (state: GuideShare) => (state.access === "anyone" ? "Anyone with the link can open it now" : "Only people with access can open it now") },
  });
  const add = useMutation({
    meta: { inline: true },
    mutationFn: async (text: string) => {
      const { emails, bad } = readAddresses(text);
      // Said here before anything is sent: expected, so not reported as a fault.
      if (bad.length) throw new ApiError(`${bad[0]} isn't an email address.`, 400);
      if (!emails.length) throw new ApiError("Type an email address, like dana@example.com.", 400);
      if (emails.length > MAX_SHARE_ADD) throw new ApiError(`Add up to ${MAX_SHARE_ADD} people at a time.`, 400);
      return { result: await api.post<Added>(`/guides/${pageId}/share/people`, { emails }), count: emails.length };
    },
    onSuccess: ({ result, count }) => {
      keep(result);
      setTyped("");
      const note = addedNote(result, count);
      if (note.ok) toast.success(note.text);
      else toast.info(note.text);
    },
  });
  const remove = useMutation({
    mutationFn: (person: SharedPerson) => api.delete<GuideShare>(`/guides/${pageId}/share/people/${person.id}`),
    onSuccess: keep,
    // With a link for anyone, taking someone off the list doesn't shut them out, so it doesn't say so.
    meta: { success: (state: GuideShare, person: SharedPerson) => (state.access === "anyone" ? `${person.email} taken off the list` : `${person.email} can't open it any more`) },
  });
  const emailAgain = useMutation({
    mutationFn: (person: SharedPerson) => api.post<{ emailed: string }>(`/guides/${pageId}/share/people/${person.id}/email`),
    meta: { success: (res: { emailed: string }) => `Link emailed to ${res.emailed}` },
  });
  const newLink = useMutation({
    mutationFn: () => api.post<GuideShare>(`/guides/${pageId}/share/link`),
    onSuccess: keep,
    meta: { success: "New link made. The old one doesn't work any more." },
  });
  const added = useJustDone(add);

  const d = share.data;
  const submit = (e: FormEvent) => {
    e.preventDefault();
    if (typed.trim()) add.mutate(typed);
  };
  const full = (d?.people.length ?? 0) >= MAX_SHARE_PEOPLE;

  return (
    <Dialog open onClose={onClose} title={`Share “${title}”`} description="A link lets people outside your team read this guide: a new hire, a subcontractor, a client." size="md">
      {share.error ? <ErrorState compact error={share.error} onRetry={() => share.refetch()} /> : !d ? (
        <div className="stack" aria-busy="true" aria-label="Loading"><Skeleton height={34} width={280} /><Skeleton height={38} /><Skeleton height={38} /></div>
      ) : (
        <div className="stack" style={{ gap: 18 }}>
          {!d.published && (
            <div className="callout callout-warning" role="status">
              <Icon name="alert" size={18} />
              <div className="grow">This guide is a draft, so its link says it isn't available. It works once the guide is published.</div>
            </div>
          )}

          <div className="stack-sm">
            <form className="row" style={{ gap: 8 }} onSubmit={submit}>
              <input
                className="input input-lg grow" style={{ minWidth: 0 }} type="text" inputMode="email" autoComplete="off" spellCheck={false}
                placeholder="Add people by email address" aria-label="Email addresses to add" disabled={full}
                value={typed} onChange={(e) => { setTyped(e.target.value); add.reset(); }}
              />
              {(typed.trim() || add.isPending || added) && <Button type="submit" size="lg" loading={add.isPending} done={added} doneLabel="Added">Add</Button>}
            </form>
            <FormError error={add.error} />
            <span className="muted small">
              {full
                ? `A guide is shared with up to ${MAX_SHARE_PEOPLE} people. To reach more, let anyone with the link open it.`
                : "Several at once with commas between them. Each gets an email with the link."}
            </span>
            {!d.email_ready && (
              <div className="callout callout-warning" role="status">
                <Icon name="mail" size={18} />
                <div className="grow">
                  Email isn't set up in Jobly yet, so nobody can be sent the link or a code. <Link to="/settings?tab=email" className="strong">Connect your email</Link>{d.access === "anyone" ? " to email it from here." : ", or let anyone with the link open it."}
                </div>
              </div>
            )}
          </div>

          <section className="stack-sm" aria-labelledby="share-people">
            <strong id="share-people">People with access</strong>
            <ul style={{ listStyle: "none", margin: 0, padding: 0, display: "grid", gap: 2 }} aria-labelledby="share-people">
              <li className="row" style={{ gap: 12, padding: "6px 0" }}>
                <span className="avatar" aria-hidden="true" style={{ width: 34, height: 34 }}><Icon name="users" size={16} /></span>
                <span className="grow stack-sm" style={{ gap: 0, minWidth: 0 }}>
                  <strong className="small">Your team</strong>
                  <span className="muted small">Reads it in Jobly, signed in</span>
                </span>
              </li>
              {d.people.map((p) => (
                <li key={p.id} className="row" style={{ gap: 12, padding: "6px 0" }}>
                  <span className="avatar" aria-hidden="true" style={{ width: 34, height: 34, fontSize: 14 }}>{p.email[0]!.toUpperCase()}</span>
                  <span className="grow stack-sm" style={{ gap: 0, minWidth: 0 }}>
                    <strong className="ellipsis small">{p.email}</strong>
                    <span className="muted small">{p.last_opened_at ? `Opened it ${timeAgo(p.last_opened_at)}` : d.access === "anyone" ? `Added ${timeAgo(p.created_at)}` : "Hasn't opened it yet"}</span>
                  </span>
                  <button type="button" className="icon-btn" title="Email them the link again" aria-label={`Email the link to ${p.email} again`} disabled={!d.email_ready || !d.published || (emailAgain.isPending && emailAgain.variables?.id === p.id)} onClick={() => emailAgain.mutate(p)}>
                    <Icon name="mail" size={16} />
                  </button>
                  <button type="button" className="icon-btn" title="Take them off" aria-label={`Take ${p.email} off`} disabled={remove.isPending && remove.variables?.id === p.id} onClick={() => remove.mutate(p)}>
                    <Icon name="x" size={16} />
                  </button>
                </li>
              ))}
            </ul>
          </section>

          <section className="stack-sm" aria-labelledby="share-who">
            <strong id="share-who">General access</strong>
            <div className="row" style={{ gap: 12, alignItems: "flex-start" }}>
              <span className="avatar" aria-hidden="true" style={{ width: 34, height: 34, background: "var(--fill-2)", color: "var(--text-2)" }}><Icon name={d.access === "anyone" ? "globe" : "lock"} size={16} /></span>
              <div className="grow stack-sm" style={{ gap: 2, minWidth: 0 }}>
                <span>
                  <Menu
                    label={`General access: ${ACCESS_LABELS[d.access]}`}
                    align="start"
                    triggerClassName="btn btn-ghost btn-sm"
                    trigger={<><strong>{ACCESS_LABELS[d.access]}</strong><Icon name="chevronDown" size={14} /></>}
                    items={GUIDE_SHARE_ACCESS.map((access) => ({
                      label: ACCESS_LABELS[access],
                      icon: d.access === access ? "check" as const : access === "anyone" ? "globe" as const : "lock" as const,
                      disabled: setAccess.isPending,
                      onSelect: () => { if (d.access !== access) setAccess.mutate(access); },
                    }))}
                  />
                </span>
                <span className="muted small" role="status" style={{ paddingLeft: 10 }}>{WHO[d.access]}</span>
              </div>
            </div>
          </section>

          <div className="form-actions">
            <Button icon="link" onClick={() => copyText(d.url, "Link copied")}>Copy link</Button>
            <Button
              variant="ghost" loading={newLink.isPending}
              onClick={async () => {
                const ok = await confirm({
                  title: "Get a new link for this guide?",
                  body: d.people.length
                    ? "The link people have now stops working right away. The people you've added stay on the list: email them the new link from here."
                    : "The link you've given out stops working right away. Use this when it's gone somewhere it shouldn't.",
                  confirmLabel: "Get a new link",
                });
                if (ok) newLink.mutate();
              }}
            >
              Get a new link
            </Button>
            <span className="spacer" />
            <Button variant="primary" onClick={onClose}>Done</Button>
          </div>
        </div>
      )}
    </Dialog>
  );
}
