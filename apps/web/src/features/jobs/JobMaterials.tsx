/**
 * Materials used on a job: tons of asphalt, gallons of sealer, loads of stone, logged from the
 * field with the plant ticket number and a photo of the ticket. Crews see quantities, never prices.
 * For the office with job costs, each one is set against what the job's line items estimated for it
 * (a price list item on the job, or a material of a paving calculator line), and counts in job
 * costing as logged in place of the estimate (packages/core/src/reports.ts materialUse).
 */
import type { MaterialUse } from "@jobly/core/reports";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState, type FormEvent } from "react";
import { featureOn } from "@/components/shell/nav";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormChecks, FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { Select } from "@/components/ui/Select";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { signedUrls, uploadFile } from "@/lib/files";
import { formatDate, formatMoneyCents } from "@/lib/format";
import { useListAnimation } from "@/lib/motion";
import { hasRole, useSession } from "@/lib/session";
import { undoable } from "@/lib/undo";
import { LOGGED_MATERIALS_RULE } from "./jobCosts";
import { intlLocale, t } from "@/lib/i18n";

const UNITS = ["ton", "yd³", "gal", "load", "bag", "ea", "lf", "sq yd"];
const qty = (n: number) => new Intl.NumberFormat(intlLocale(), { maximumFractionDigits: 3 }).format(n);

const materialsKey = (jobId: string) => ["job", jobId, "materials"];

export function useJobMaterials(jobId: string) {
  return useQuery({
    queryKey: materialsKey(jobId),
    queryFn: async () => {
      const rows = unwrap(await supabase().from("job_materials").select("id, visit_id, service_id, name, quantity, unit, ticket, supplier, photo_path, logged_by, logged_at").eq("job_id", jobId).order("logged_at", { ascending: false }));
      const urls = await signedUrls(rows.flatMap((r) => (r.photo_path ? [r.photo_path] : []))).catch(() => ({}) as Record<string, string>);
      return rows.map((r) => ({ ...r, photo_url: r.photo_path ? urls[r.photo_path] ?? null : null }));
    },
  });
}
type Material = NonNullable<ReturnType<typeof useJobMaterials>["data"]>[number];

/**
 * On the job page (all of it) or a visit (just that day's), with a "Log material" button. The job
 * page shows it once something's logged, or opens it with the dialog up (startAdding) from its add
 * buttons; onAddClosed tells it that dialog has closed, so an empty card can go again. `use`: each
 * logged material against the job's estimate (jobCosts), for the office with job costs.
 */
export function MaterialsCard({ jobId, visitId, showCosts, use, compact = false, startAdding = false, onAddClosed }: { jobId: string; visitId?: string; showCosts?: boolean; use?: readonly MaterialUse[]; compact?: boolean; startAdding?: boolean; onAddClosed?: () => void }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const [logging, setLogging] = useState(startAdding);
  const listRef = useListAnimation<HTMLDivElement>();
  const materials = useJobMaterials(jobId);
  const costs = useQuery({
    queryKey: ["job", jobId, "material-costs"],
    enabled: Boolean(showCosts),
    queryFn: async () => unwrap(await supabase().rpc("job_material_costs", { p_job: jobId })),
  });
  const remove = useMutation({
    meta: { inline: true },
    mutationFn: async (id: string) => unwrap(await supabase().from("job_materials").delete().eq("id", id)),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["job", jobId] }),
  });
  // Gone at once with Undo on the toast; deleted for real once the toast leaves.
  const removeEntry = (m: Material) => {
    const key = materialsKey(jobId);
    undoable({
      title: t("Material removed"),
      tone: "job",
      hide: () => {
        void queryClient.cancelQueries({ queryKey: key });
        queryClient.setQueryData<Material[]>(key, (all) => all?.filter((x) => x.id !== m.id));
      },
      restore: () => queryClient.setQueryData<Material[]>(key, (all) => (all && !all.some((x) => x.id === m.id) ? [...all, m].sort((a, b) => b.logged_at.localeCompare(a.logged_at)) : all)),
      commit: () => remove.mutateAsync(m.id),
    });
  };
  const closeLog = () => {
    setLogging(false);
    onAddClosed?.();
  };
  const rows = (materials.data ?? []).filter((m) => !visitId || m.visit_id === visitId);
  const canFix = (m: { logged_by: string | null; logged_at: string }) => hasRole(session, "admin", "office", "crew_lead") || (m.logged_by === session.userId && Date.now() - Date.parse(m.logged_at) < 86_400_000);
  // Totals by material, for the whole job.
  const totals = Object.values(
    (materials.data ?? []).reduce<Record<string, { name: string; unit: string; quantity: number }>>((acc, m) => {
      const k = `${m.name}|${m.unit}`;
      acc[k] = { name: m.name, unit: m.unit, quantity: (acc[k]?.quantity ?? 0) + Number(m.quantity) };
      return acc;
    }, {}),
  );

  return (
    <section className={compact ? "card card-pad stack-sm" : "stack"}>
      <div className={compact ? "row-between" : "section-head"}>
        {compact ? <strong>{t("Materials used")}</strong> : <h2 className="section-title">{t("Materials used")}</h2>}
        <Button size="sm" icon="plus" onClick={() => setLogging(true)}>{t("Log material")}</Button>
      </div>
      <div className={compact ? undefined : "card"} ref={listRef}>
        {materials.isPending && <div className="card-row"><Skeleton width="50%" /></div>}
        {materials.data && rows.length === 0 && (
          <EmptyState inline title={visitId ? t("Nothing logged yet") : t("No materials logged yet")}>
            {visitId ? t("Log tons, gallons or loads as they come in, with the ticket number.") : null}
          </EmptyState>
        )}
        {rows.map((m) => (
          <div key={m.id} className="card-row" style={compact ? { paddingLeft: 0, paddingRight: 0 } : undefined}>
            {m.photo_url ? (
              <a href={m.photo_url} target="_blank" rel="noreferrer" className="thumb" style={{ width: 38, height: 38, flex: "none" }} aria-label={t("Open ticket photo")}><img src={m.photo_url} alt="" /></a>
            ) : (
              <span style={{ width: 38, height: 38, borderRadius: 8, display: "grid", placeItems: "center", background: "var(--fill-2)", color: "var(--text-3)", flex: "none" }}><Icon name="truck" size={16} /></span>
            )}
            <span className="grow" style={{ minWidth: 0 }}>
              <strong>{qty(Number(m.quantity))} {m.unit} · {m.name}</strong>
              <span className="muted small" style={{ display: "block" }}>{[m.ticket && t("Ticket {ticket}", { ticket: m.ticket }), m.supplier, formatDate(m.logged_at)].filter(Boolean).join(" · ")}</span>
            </span>
            {canFix(m) && <Button size="sm" variant="ghost" icon="trash" aria-label={t("Remove {tag}", { tag: m.name })} onClick={() => removeEntry(m)} />}
          </div>
        ))}
        {!visitId && totals.length > 1 && (
          <div className="list-foot"><span className="muted small">{t("Totals: {list}", { list: totals.map((x) => `${qty(x.quantity)} ${x.unit} ${x.name}`).join(" · ") })}</span></div>
        )}
      </div>
      {showCosts && !!use?.length && <EstimatedAndUsed use={use} priceList={costs.data ?? []} />}
      {logging && <MaterialDialog jobId={jobId} visitId={visitId ?? null} onClose={closeLog} onSaved={() => queryClient.invalidateQueries({ queryKey: ["job", jobId] })} />}
    </section>
  );
}

/**
 * Each logged material against what the job's line items estimated for it. One that's on the lines
 * counts in job costing as logged, at the line's cost; one that isn't is listed with what the price
 * list says it costs, and isn't counted, since a line's cost may already cover it. The rule is said
 * here, where the numbers are.
 */
function EstimatedAndUsed({ use, priceList }: { use: readonly MaterialUse[]; priceList: ReadonlyArray<{ name: string; unit: string; unit_cost: number | null; cost: number | null }> }) {
  const compared = use.filter((r) => r.estimated !== null);
  const others = use.filter((r) => r.estimated === null);
  const listCost = (r: MaterialUse) => priceList.find((c) => c.name === r.name && c.unit === r.unit && c.unit_cost != null)?.cost ?? null;
  return (
    <div className="card card-pad stack-sm">
      <strong>{t("Estimated and used")}</strong>
      {compared.map((r) => {
        const over = Math.round((r.used - r.estimated!) * 1000) / 1000;
        return (
          <div key={`${r.name}|${r.unit}`} className="row-between" style={{ alignItems: "flex-start", gap: 12 }}>
            <span>
              {r.name}
              <span className="muted small" style={{ display: "block" }}>{t("Estimated {quantity} {unit} · {cost}", { quantity: qty(r.estimated!), unit: r.unit, cost: formatMoneyCents(r.estimated_cost!) })}</span>
            </span>
            <span style={{ textAlign: "right" }}>
              <strong className="tabular">{qty(r.used)} {r.unit} · {formatMoneyCents(r.actual_cost!)}</strong>
              <span className="muted small" style={{ display: "block" }}>{over === 0 ? t("As estimated") : over > 0 ? t("{quantity} {unit} over", { quantity: qty(Math.abs(over)), unit: r.unit }) : t("{quantity} {unit} under", { quantity: qty(Math.abs(over)), unit: r.unit })}</span>
            </span>
          </div>
        );
      })}
      {others.map((r) => {
        const cost = listCost(r);
        return (
          <div key={`${r.name}|${r.unit}`} className="row-between" style={{ alignItems: "flex-start", gap: 12 }}>
            <span>
              {r.name}
              <span className="muted small" style={{ display: "block" }}>{t("Not on this job's line items")}</span>
            </span>
            <span className="muted tabular" style={{ textAlign: "right" }}>{qty(r.used)} {r.unit}{cost != null ? ` · ${t("{cost} at price list cost", { cost: formatMoneyCents(Number(cost)) })}` : ""}</span>
          </div>
        );
      })}
      <span className="muted small">
        {LOGGED_MATERIALS_RULE}
        {others.length > 0 && t(" A material that isn't on the line items is listed, not counted: a line's cost may already cover it.")}
      </span>
    </div>
  );
}

/** onSaved may return a promise (a refetch): the dialog stays until it's done, so the new row is there as it closes. */
export function MaterialDialog({ jobId, visitId, onClose, onSaved }: { jobId: string; visitId: string | null; onClose: () => void; onSaved: () => unknown }) {
  const session = useSession();
  const choices = useQuery({
    queryKey: ["material-choices", session.company.id],
    staleTime: 5 * 60_000,
    queryFn: async () => unwrap(await supabase().rpc("material_choices", { p_company: session.company.id })),
  });
  // What the job's own lines have on them, by name and unit (no prices): logged as one of these, a
  // material is set against the job's estimate. Not on the phone with no signal; the rest still is.
  const onJob = useQuery({
    queryKey: ["job", jobId, "estimated-materials"],
    staleTime: 5 * 60_000,
    meta: { silent: true },
    queryFn: async () => unwrap(await supabase().rpc("job_estimated_materials", { p_job: jobId })),
  });
  // The list's value: a price list item's id, or one of the job's own ("job:" and its place in onJob).
  const [choice, setChoice] = useState("");
  const [serviceId, setServiceId] = useState("");
  const [name, setName] = useState("");
  const [quantity, setQuantity] = useState("");
  // Tons are paving's; everyone else counts each.
  const [unit, setUnit] = useState(() => (featureOn(session.company.settings, "paving_app") ? "ton" : "ea"));
  const [ticket, setTicket] = useState("");
  const [supplier, setSupplier] = useState("");
  const [file, setFile] = useState<File | null>(null);
  const amount = Number(quantity);
  const pick = (id: string) => {
    setChoice(id);
    const mine = id.startsWith("job:") ? onJob.data?.[Number(id.slice(4))] : undefined;
    setServiceId(mine ? mine.service_id ?? "" : id);
    const c = mine ?? choices.data?.find((x) => x.id === id);
    if (c) {
      setName(c.name);
      setUnit(c.unit);
    }
  };
  const save = useMutation({
    meta: { inline: true, success: t("Material logged") },
    mutationFn: async () => {
      if (!(amount > 0)) throw new Error(t("Enter how much was used."));
      if (!name.trim()) throw new Error(t("Say what material it was."));
      const photo_path = file ? await uploadFile(session.company.id, `tickets/${jobId}`, file) : null;
      unwrap(
        await supabase().from("job_materials").insert({
          company_id: session.company.id, job_id: jobId, visit_id: visitId, service_id: serviceId || null,
          name: name.trim(), quantity: amount, unit, ticket: ticket.trim() || null, supplier: supplier.trim() || null, photo_path,
          logged_by: session.userId,
        }),
      );
    },
    onSuccess: async () => {
      await onSaved();
      onClose();
    },
  });
  return (
    <Dialog open onClose={onClose} title={t("Log material")}>
      <form onSubmit={(e: FormEvent) => { e.preventDefault(); save.mutate(); }}>
        <Field label={t("Material")}>
          {choices.isPending ? <Skeleton height={38} radius={8} /> : (
            <Select className="select" value={choice} onChange={(e) => pick(e.target.value)}>
              <option value="">{t("Something else (type it below)")}</option>
              {!!onJob.data?.length && (
                <optgroup label={t("On this job")}>
                  {onJob.data.map((c, i) => <option key={`job:${i}`} value={`job:${i}`}>{c.name} ({c.unit})</option>)}
                </optgroup>
              )}
              {onJob.data?.length ? (
                <optgroup label={t("Price list")}>
                  {choices.data?.map((c) => <option key={c.id} value={c.id}>{c.name} ({c.unit})</option>)}
                </optgroup>
              ) : choices.data?.map((c) => <option key={c.id} value={c.id}>{c.name} ({c.unit})</option>)}
            </Select>
          )}
        </Field>
        {!choice && <Field label={t("What was it")} requiredMessage={t("Say what material it was.")}><input className="input" value={name} onChange={(e) => setName(e.target.value)} maxLength={200} placeholder={t("Surface mix, #57 stone, sealer…")} required /></Field>}
        <div className="form-grid">
          <Field label={t("How much")} requiredMessage={t("Enter how much was used.")}><input className="input" inputMode="decimal" value={quantity} onChange={(e) => setQuantity(e.target.value.replace(/[^0-9.]/g, ""))} required autoFocus /></Field>
          <Field label={t("Unit")}>
            <Select className="select" value={unit} onChange={(e) => setUnit(e.target.value)}>
              {[...new Set([unit, ...UNITS])].map((u) => <option key={u}>{u}</option>)}
            </Select>
          </Field>
          <Field label={t("Ticket number")} optional><input className="input" value={ticket} onChange={(e) => setTicket(e.target.value)} maxLength={60} /></Field>
          <Field label={t("Supplier or plant")} optional><input className="input" value={supplier} onChange={(e) => setSupplier(e.target.value)} maxLength={120} /></Field>
        </div>
        <label className="dropzone" style={{ padding: 14 }}>
          <Icon name="camera" size={20} />
          <span className="small strong">{file ? file.name : t("Add a photo of the ticket")}</span>
          <input type="file" accept="image/*" capture="environment" className="sr-only" onChange={(e) => setFile(e.target.files?.[0] ?? null)} />
        </label>
        <FormError error={save.error} />
        <div className="form-actions">
          <FormChecks />
          <Button onClick={onClose}>{t("Cancel")}</Button>
          {/* With a ticket photo it uploads, which is slow anyway. */}
          <Button type="submit" variant="primary" loading={save.isPending} slowHint={file ? false : undefined}>{t("Log it")}</Button>
        </div>
      </form>
    </Dialog>
  );
}
