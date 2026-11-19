/**
 * The history of one time entry on Timesheets (everything the database has on record for it:
 * timeChanges.ts), and deleting someone else's time, which asks why and tells them.
 */
import { useMutation, useQuery } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormError } from "@/components/ui/Field";
import { Loading } from "@/components/ui/Skeleton";
import { ErrorState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { formatDateTime } from "@/lib/format";
import { t } from "@/lib/i18n";
import { useSession } from "@/lib/session";
import { changedBy, changeLines, loadEntryChanges, spanLabel, type TimeChange } from "./timeChanges";

/** One change: when, who or what, what it did and why. */
export function ChangeItem({ change, name }: { change: TimeChange; name: (id: string) => string }) {
  const session = useSession();
  const tz = session.company.timezone;
  return (
    <li className="stack-sm" style={{ gap: 2, padding: "10px 0", borderBottom: "1px solid var(--row-divider)" }}>
      <span className="small muted">{formatDateTime(change.changed_at, tz)} · {changedBy(change, session.userId, name)}</span>
      {changeLines(change, tz).map((line) => <span key={line}>{line}</span>)}
      {change.reason && <span className="small">{t("Why: {reason}", { reason: change.reason })}</span>}
    </li>
  );
}

/** Everything on record for an entry, newest first. `what` says which entry: its day and times. */
export function TimeHistoryDialog({ entryId, what, name, onClose }: { entryId: string; what: string; name: (id: string) => string; onClose: () => void }) {
  const changes = useQuery({ queryKey: ["time-history", entryId], queryFn: () => loadEntryChanges(entryId) });
  return (
    <Dialog open onClose={onClose} title={t("History")} description={what}>
      <div className="dialog-body">
        {changes.isPending && <Loading><span className="muted">{t("Loading…")}</span></Loading>}
        {changes.error && <ErrorState error={changes.error} onRetry={() => changes.refetch()} />}
        {changes.data && changes.data.length === 0 && <p className="muted">{t("Nothing has changed since this time was clocked.")}</p>}
        {changes.data && changes.data.length > 0 && (
          <ul style={{ listStyle: "none", margin: 0, padding: 0 }}>
            {[...changes.data].reverse().map((change) => <ChangeItem key={change.id} change={change} name={name} />)}
          </ul>
        )}
        <p className="small muted">{t("Every change to a time entry is kept here, with who made it and when. It can't be edited or deleted.")}</p>
      </div>
      <div className="form-actions">
        <Button onClick={onClose}>{t("Close")}</Button>
      </div>
    </Dialog>
  );
}

/** Deleting someone else's time: why (kept with the record of it), and they're told. */
export function DeleteTimeDialog({ entry, person, onClose, onDeleted }: { entry: { id: string; started_at: string; ended_at: string | null }; person: string; onClose: () => void; onDeleted: () => void }) {
  const session = useSession();
  const [reason, setReason] = useState("");
  const remove = useMutation({
    meta: { inline: true, success: t("Time entry deleted") },
    mutationFn: async () => unwrap(await supabase().rpc("delete_time_entry", { p_entry: entry.id, p_reason: reason.trim() || undefined })),
    onSuccess: () => {
      onDeleted();
      onClose();
    },
  });
  return (
    <Dialog open onClose={onClose} title={t("Delete {name}'s time?", { name: person })} description={spanLabel(entry.started_at, entry.ended_at, session.company.timezone)}>
      <form onSubmit={(e: FormEvent) => { e.preventDefault(); remove.mutate(); }}>
        <Field label={t("Why it's being deleted")} optional hint={t("{name} is told. The entry stays on record as deleted, with who deleted it and when.", { name: person })}>
          <input className="input" value={reason} onChange={(e) => setReason(e.target.value)} maxLength={300} />
        </Field>
        <FormError error={remove.error} />
        <div className="form-actions">
          <Button onClick={onClose}>{t("Cancel")}</Button>
          <Button type="submit" variant="danger" loading={remove.isPending}>{t("Delete")}</Button>
        </div>
      </form>
    </Dialog>
  );
}
