/**
 * Several receipts or supplier invoices at once, for the office with job costs: each file dropped or
 * picked is uploaded to the receipts folder, becomes a draft (public.expense_drafts) and is read
 * (apps/api/src/routes/receipts.ts) when reading is on. The drafts wait in a list to be checked and
 * saved one by one as expenses (ExpenseDialog), or discarded. Until then nothing counts them: they
 * aren't expenses. On a job's Expenses, its own; on Finance → Profit, all of them.
 *
 * With reading off the drop zone says so, and what's dropped waits "to fill in": nothing was tried,
 * so nothing failed. One that couldn't be sent to be read (a server from before this, no
 * connection) says why on its row rather than sitting at "Reading…" (receiptDraftWords.ts).
 */
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Icon } from "@/components/ui/Icon";
import { Menu } from "@/components/ui/Menu";
import { api, supabase, unwrap } from "@/lib/api";
import { errorMessage } from "@/lib/errors";
import { uploadFile } from "@/lib/files";
import { formatDate, formatMoneyCents } from "@/lib/format";
import { everyRow } from "@/lib/paging";
import { can, hasRole, useSession } from "@/lib/session";
import { toast } from "@/lib/toast";
import { ExpenseDialog } from "./ExpensesCard";
import { draftState, dropZoneOff, nextWaiting, READ_IT, TO_FILL_LINE, unreadReason, WAITING_LINE, WAITING_RETRY_MS, WAITING_WHY } from "./receiptDraftWords";
import { readingOn, type ReadAnswer } from "./receiptReading";
import { translateError } from "@jobly/core/i18n/patterns";
import { getLocale, t } from "@/lib/i18n";

export interface ExpenseDraft {
  id: string;
  job_id: string | null;
  receipt_path: string;
  file_name: string | null;
  status: string;
  read: ReadAnswer | null;
  error: string | null;
  created_at: string;
  /** When it last changed: sent to be read again, read, or marked. */
  updated_at?: string | null;
  job?: { number: number | null; title: string } | null;
}

const draftsKey = (companyId: string, jobId?: string) => ["receipt-drafts", companyId, jobId ?? "all"];

/** The drafts waiting: a job's, or (no job) all of them. Asked again every few seconds while any is being read. */
export function useReceiptDrafts(jobId?: string) {
  const session = useSession();
  const seesCosts = hasRole(session, "admin", "office") && can(session, "job_costs");
  return useQuery({
    queryKey: draftsKey(session.company.id, jobId),
    enabled: seesCosts,
    refetchInterval: (q) => ((q.state.data as ExpenseDraft[] | undefined)?.some((d) => draftState(d, Date.now()) === "reading") ? 4000 : false),
    queryFn: async () => {
      const rows = await everyRow(() => {
        const q = supabase().from("expense_drafts").select("id, job_id, receipt_path, file_name, status, read, error, created_at, updated_at, job:jobs(number, title)").eq("company_id", session.company.id);
        return jobId ? q.eq("job_id", jobId) : q;
      }, { order: "created_at" });
      return rows as unknown as ExpenseDraft[];
    },
  });
}

export function ReceiptDrafts({ jobId, onSaved }: { jobId?: string; onSaved?: () => unknown }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const seesCosts = hasRole(session, "admin", "office") && can(session, "job_costs");
  const drafts = useReceiptDrafts(jobId);
  const [over, setOver] = useState(false);
  const [checking, setChecking] = useState<ExpenseDraft | null>(null);
  const [adding, setAdding] = useState(0);
  const refresh = () => queryClient.invalidateQueries({ queryKey: ["receipt-drafts", session.company.id] });
  const on = readingOn(session.company.settings);
  const off = dropZoneOff(on, hasRole(session, "admin"));

  // Sent to be read. If it can't even be sent (a server from before this, no connection), the draft
  // says why and is there to fill in, rather than waiting at "Reading…" for an answer that won't come.
  const read = async (id: string) => {
    try {
      await supabase().from("expense_drafts").update({ status: "reading", error: null }).eq("id", id).in("status", ["failed", "to_fill", "waiting"]);
      return (await api.post<{ draft: { status: string } | null }>(`/receipts/drafts/${id}/read`)).draft?.status ?? null;
    } catch (error) {
      await supabase().from("expense_drafts").update({ status: "failed", error: unreadReason(error) }).eq("id", id).eq("status", "reading");
      return null;
    } finally {
      void refresh();
    }
  };

  // More dropped than can be read in an hour: the rest wait their turn (the server marks them), and
  // this asks again every few minutes while the page is open, oldest first, until one is told to
  // keep waiting. So a big stack carries on by itself instead of failing part-way.
  const waiting = (drafts.data ?? []).some((d) => d.status === "waiting");
  const latest = useRef({ drafts: drafts.data ?? [], read });
  latest.current = { drafts: drafts.data ?? [], read };
  useEffect(() => {
    if (!waiting || !on) return;
    let busy = false;
    const carryOn = async () => {
      if (busy) return;
      busy = true;
      try {
        const asked = new Set<string>();
        for (let next = nextWaiting(latest.current.drafts); next && !asked.has(next.id); next = nextWaiting(latest.current.drafts.filter((d) => !asked.has(d.id)))) {
          asked.add(next.id);
          if ((await latest.current.read(next.id)) === "waiting") break;
        }
      } finally {
        busy = false;
      }
    };
    const timer = setInterval(() => void carryOn(), WAITING_RETRY_MS);
    return () => clearInterval(timer);
  }, [waiting, on]);
  // Each file uploaded and made a draft, then read: two at a time, so a stack of them doesn't wait on one.
  const add = async (files: FileList | null) => {
    const list = [...(files ?? [])];
    if (!list.length) return;
    setAdding((n) => n + list.length);
    const failed: string[] = [];
    const one = async (file: File) => {
      try {
        const receipt_path = await uploadFile(session.company.id, "receipts", file);
        // With reading off nothing is sent anywhere: it waits to be filled in.
        const draft = unwrap(await supabase().from("expense_drafts").insert({ company_id: session.company.id, job_id: jobId ?? null, receipt_path, file_name: file.name.slice(0, 255), ...(on ? {} : { status: "to_fill" }) }).select("id").single());
        void refresh();
        if (on) await read(draft.id);
      } catch (error) {
        failed.push(`${file.name}: ${errorMessage(error)}`);
      } finally {
        setAdding((n) => n - 1);
      }
    };
    const queue = [...list];
    await Promise.all([0, 1].map(async () => { for (let f = queue.shift(); f; f = queue.shift()) await one(f); }));
    if (failed.length) toast.error(failed.length === 1 ? t("A file couldn't be added") : t("{count} files couldn't be added", { count: failed.length }), { description: failed.join("\n") });
  };
  const discard = useMutation({
    meta: { success: t("Receipt discarded") },
    mutationFn: async (id: string) => unwrap(await supabase().from("expense_drafts").delete().eq("id", id)),
    onSettled: refresh,
  });

  if (!seesCosts) return null;
  const rows = drafts.data ?? [];
  const firstWaiting = rows.find((d) => d.status === "waiting")?.id;
  return (
    <div className="stack-sm">
      {rows.length > 0 && (
        <div className="card">
          <div className="card-row"><strong className="grow small">{t("Receipts to check and save")}</strong><span className="muted small">{rows.length}</span></div>
          {rows.map((d) => {
            const r = d.read?.reading;
            const state = draftState(d, Date.now());
            const job = d.job ?? (d.read?.job ? { number: d.read.job.number, title: d.read.job.title } : null);
            return (
              <div key={d.id} className="card-row">
                <span className="n-icon" style={{ width: 36, height: 36, borderRadius: 8, display: "grid", placeItems: "center", background: "var(--fill-2)", color: "var(--text-3)", flex: "none" }}><Icon name="receipt" size={18} /></span>
                <span className="grow">
                  <strong>{r?.vendor || d.file_name || t("Receipt")}</strong>
                  <span className="muted small" style={{ display: "block" }}>
                    {state === "reading" ? t("Reading…")
                      : state === "to_fill" || state === "waiting" ? [state === "waiting" ? WAITING_LINE : TO_FILL_LINE, !jobId && d.job ? t("Job #{number}", { number: d.job.number }) : null].filter(Boolean).join(" · ")
                        : state === "failed" ? t("Couldn't be read: fill it in")
                          : [r?.total != null ? formatMoneyCents(r.total) : null, r?.date ? formatDate(r.date) : null, !jobId && job ? (d.job ? t("Job #{number}", { number: job.number }) : t("Job #{number} (suggested)", { number: job.number })) : null, d.read?.problems.length ? t("{count} to check", { count: d.read.problems.length }) : null].filter(Boolean).join(" · ")}
                  </span>
                  {/* Why, when it's known: reading is off now, the server is from before this, the file couldn't be opened. */}
                  {state === "failed" && d.error && <span className="muted small" style={{ display: "block" }}>{translateError(getLocale(), d.error)}</span>}
                  {state === "waiting" && d.id === firstWaiting && <span className="muted small" style={{ display: "block" }}>{WAITING_WHY}</span>}
                </span>
                <Button size="sm" disabled={state === "reading"} onClick={() => setChecking(d)}>{t("Check and save")}</Button>
                <Menu
                  triggerClassName="btn btn-sm btn-ghost btn-icon"
                  label={t("Receipt actions")}
                  items={[
                    { label: state === "failed" ? t("Read again") : READ_IT, icon: "refresh", hidden: !(state === "failed" || ((state === "to_fill" || state === "waiting") && on)), onSelect: () => void read(d.id) },
                    { label: t("Discard"), icon: "trash", danger: true, onSelect: () => discard.mutate(d.id) },
                  ]}
                />
              </div>
            );
          })}
        </div>
      )}
      <label
        className="dropzone"
        style={{ padding: 12 }}
        data-over={over || undefined}
        onDragOver={(e) => { e.preventDefault(); setOver(true); }}
        onDragLeave={() => setOver(false)}
        onDrop={(e) => { e.preventDefault(); setOver(false); void add(e.dataTransfer.files); }}
      >
        <Icon name="upload" size={18} />
        <span className="small strong">{adding > 0 ? t("Adding {count}…", { count: adding }) : t("Drop several receipts or supplier invoices here, or click to choose")}</span>
        <span className="small muted">{off ? off.hint : t("Photos or PDFs. Each waits here to be checked and saved: none counts in job costing until it is.")}</span>
        <input type="file" multiple accept="image/*,application/pdf" className="sr-only" onChange={(e) => { void add(e.target.files); e.target.value = ""; }} />
      </label>
      {checking && (
        <ExpenseDialog
          jobId={jobId ?? null}
          expense={null}
          draft={checking}
          onClose={() => setChecking(null)}
          onSaved={async () => {
            await refresh();
            await onSaved?.();
          }}
        />
      )}
    </div>
  );
}
