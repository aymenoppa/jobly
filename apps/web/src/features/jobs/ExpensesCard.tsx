/**
 * Materials, dump fees and other costs on a job, with receipt photos. Feeds job costing.
 *
 * With the company's reading switch on (Settings → Company), a photo or PDF picked in Add expense is
 * read (receiptReading.ts) and fills in the form, marked as read, for the person to check and save.
 * A supplier's invoice also brings its lines, which the office can log as the job's materials used
 * in the same save: what's logged against the job's estimate counts through its line items and the
 * rest as an expense, once each (expenseMaterials.ts has the rule). A receipt that looks to be in
 * already is asked about before it's saved again. Several at once go in as drafts to confirm
 * (ReceiptDrafts).
 */
import { TRASH_DAYS } from "@jobly/core/drive";
import { EXPENSE_CATEGORIES as CATEGORIES, lineAmount, type ReadField, type ReceiptLine } from "@jobly/core/receipts";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState, type FormEvent } from "react";
import { AnimatedNumber, MONEY_CENTS } from "@/components/ui/AnimatedNumber";
import { Button } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Dialog } from "@/components/ui/Dialog";
import { Field, FormChecks, FormError } from "@/components/ui/Field";
import { Icon } from "@/components/ui/Icon";
import { Menu } from "@/components/ui/Menu";
import { Select } from "@/components/ui/Select";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { signedUrls, uploadFile } from "@/lib/files";
import { formatDate, formatMoneyCents, todayIn } from "@/lib/format";
import { useListAnimation } from "@/lib/motion";
import { everyRow } from "@/lib/paging";
import { can, hasRole, useSession } from "@/lib/session";
import { undoable } from "@/lib/undo";
import { CostingNote, LineAlreadyLogged } from "./expenseChecks";
import { lookalikes, materialsPlan, sameReceiptQuestion, type KnownExpense, type LoggedBefore } from "./expenseMaterials";
import { ReceiptDrafts, useReceiptDrafts, type ExpenseDraft } from "./ReceiptDrafts";
import { readFieldsText, readingOn, readPickedFile, suggestedJobText, type ReadAnswer } from "./receiptReading";
import { translateError } from "@jobly/core/i18n/patterns";
import { getLocale, intlLocale, msg, t } from "@/lib/i18n";

export const EXPENSE_CATEGORIES: readonly string[] = CATEGORIES;

interface Expense {
  id: string;
  vendor: string | null;
  description: string | null;
  category: string | null;
  amount: number;
  /** The tax the receipt shows, included in amount. */
  tax_amount?: number | null;
  incurred_on: string;
  receipt_path: string | null;
  reimbursable: boolean;
  reimbursed_at: string | null;
  /** Already in the job's line item costs (the supplier's invoice for materials the estimate covers): job costing doesn't count it again. */
  in_line_costs: boolean;
  /** A supplier invoice's lines, as read from it. */
  line_items?: unknown;
}

const expensesKey = (jobId: string) => ["job", jobId, "expenses"];

/** A job's expenses with their receipt links, newest first. The job page asks too, to know whether to show the card. */
export function useJobExpenses(jobId: string, enabled = true) {
  return useQuery({
    queryKey: expensesKey(jobId),
    enabled,
    queryFn: async () => {
      const rows = unwrap(await supabase().from("expenses").select("id, vendor, description, category, amount, tax_amount, incurred_on, receipt_path, reimbursable, reimbursed_at, in_line_costs, line_items").eq("job_id", jobId).order("incurred_on", { ascending: false }));
      const urls = await signedUrls(rows.flatMap((r) => (r.receipt_path ? [r.receipt_path] : []))).catch(() => ({}) as Record<string, string>);
      return rows.map((r) => ({ ...r, receipt_url: r.receipt_path ? urls[r.receipt_path] ?? null : null }));
    },
  });
}
type ExpenseRow = NonNullable<ReturnType<typeof useJobExpenses>["data"]>[number];

/**
 * The job page shows it once the job has an expense (or a receipt waiting to be confirmed), or opens
 * it with the dialog up (startAdding) from its add buttons; onAddClosed tells it that dialog has
 * closed, so an empty card can go again.
 */
export function ExpensesCard({ jobId, onChanged, startAdding = false, onAddClosed }: { jobId: string; onChanged: () => void; startAdding?: boolean; onAddClosed?: () => void }) {
  const queryClient = useQueryClient();
  const [editing, setEditing] = useState<Expense | "new" | null>(startAdding ? "new" : null);
  const listRef = useListAnimation<HTMLDivElement>();
  const key = expensesKey(jobId);
  const expenses = useJobExpenses(jobId);
  const drafts = useReceiptDrafts(jobId);
  const refresh = () => {
    onChanged();
    // A supplier invoice's lines may have been logged as materials with it.
    void queryClient.invalidateQueries({ queryKey: ["job", jobId, "materials"] });
    return queryClient.invalidateQueries({ queryKey: key });
  };
  // Its receipt photo goes to the Trash by itself (the database moves it).
  const remove = useMutation({
    meta: { inline: true },
    mutationFn: async (e: Expense) => unwrap(await supabase().from("expenses").delete().eq("id", e.id)),
    onSuccess: () => void refresh(),
  });
  // Gone at once with Undo on the toast; deleted for real once the toast leaves, its receipt to the Trash.
  const removeLater = (e: ExpenseRow) =>
    undoable({
      title: t("Expense deleted"),
      description: e.receipt_path ? t("Its receipt photo goes to the Trash for {days} days.", { days: TRASH_DAYS }) : undefined,
      tone: "job",
      hide: () => {
        void queryClient.cancelQueries({ queryKey: key });
        queryClient.setQueryData<ExpenseRow[]>(key, (rows) => rows?.filter((r) => r.id !== e.id));
      },
      restore: () => queryClient.setQueryData<ExpenseRow[]>(key, (rows) => (rows && !rows.some((r) => r.id === e.id) ? [...rows, e].sort((a, b) => b.incurred_on.localeCompare(a.incurred_on)) : rows)),
      commit: () => remove.mutateAsync(e),
    });
  const close = () => {
    setEditing(null);
    onAddClosed?.();
  };
  const reimburse = useMutation({
    meta: { success: t("Marked reimbursed") },
    mutationFn: async (id: string) => unwrap(await supabase().from("expenses").update({ reimbursed_at: new Date().toISOString() }).eq("id", id)),
    onSuccess: refresh,
  });
  const total = expenses.data?.reduce((s, e) => s + Number(e.amount), 0) ?? 0;

  return (
    <section className="stack">
      <div className="section-head">
        <h2 className="section-title">{t("Expenses")}</h2>
        {!!expenses.data?.length && <AnimatedNumber className="muted tabular" value={total} format={MONEY_CENTS} />}
        <Button size="sm" icon="plus" onClick={() => setEditing("new")}>{t("Add expense")}</Button>
      </div>
      <div className="card" ref={listRef}>
        {expenses.isPending && [0, 1].map((i) => <div key={i} className="card-row"><Skeleton width={40} height={40} radius={8} /><span className="grow stack-sm"><Skeleton width="40%" /><Skeleton width="25%" height={10} /></span><Skeleton width={70} /></div>)}
        {expenses.data?.length === 0 && !drafts.data?.length && <EmptyState inline title={t("No expenses yet")} />}
        {expenses.data?.map((e) => (
          <div key={e.id} className="card-row">
            {e.receipt_url ? (
              <a href={e.receipt_url} target="_blank" rel="noreferrer" className="thumb" style={{ width: 40, height: 40, flex: "none" }} aria-label={t("Open receipt")}><img src={e.receipt_url} alt="" /></a>
            ) : (
              <span className="n-icon" style={{ width: 40, height: 40, borderRadius: 8, display: "grid", placeItems: "center", background: "var(--fill-2)", color: "var(--text-3)", flex: "none" }}><Icon name="receipt" size={20} /></span>
            )}
            <span className="grow">
              <strong>{e.vendor || e.category || t("Expense")}</strong>
              <span className="muted small" style={{ display: "block" }}>
                {[e.category, e.description, formatDate(e.incurred_on)].filter(Boolean).join(" · ")}
                {e.reimbursable && (e.reimbursed_at ? t(" · reimbursed") : t(" · to reimburse"))}
                {e.in_line_costs && t(" · already in the line items, not counted again")}
              </span>
            </span>
            <strong className="tabular">{formatMoneyCents(e.amount)}</strong>
            <Menu
              triggerClassName="btn btn-sm btn-ghost btn-icon"
              label={t("Expense actions")}
              items={[
                { label: t("Edit"), icon: "edit", onSelect: () => setEditing(e) },
                { label: t("Mark reimbursed"), icon: "check", hidden: !e.reimbursable || Boolean(e.reimbursed_at), onSelect: () => reimburse.mutate(e.id) },
                { label: t("Delete"), icon: "trash", danger: true, onSelect: () => removeLater(e) },
              ]}
            />
          </div>
        ))}
      </div>
      {/* Several receipts or supplier invoices at once, each a draft to check and confirm. */}
      <ReceiptDrafts jobId={jobId} onSaved={refresh} />
      {editing && <ExpenseDialog jobId={jobId} expense={editing === "new" ? null : editing} onClose={close} onSaved={refresh} />}
    </section>
  );
}

/**
 * The expenses that might be the receipt about to be saved: the ones with its invoice number, and
 * the ones from its vendor on its day. Read as the person saving, so only what they can see.
 */
async function knownExpenses(companyId: string, vendor: string | null, date: string, invoiceNumber: string | null): Promise<KnownExpense[]> {
  const columns = "id, vendor, amount, receipt_total, incurred_on, invoice_number, receipt_path, job:jobs(number)";
  const like = (s: string) => s.replace(/[\\%_]/g, (m) => `\\${m}`);
  const asks = [
    ...(invoiceNumber ? [supabase().from("expenses").select(columns).eq("company_id", companyId).ilike("invoice_number", like(invoiceNumber)).limit(20)] : []),
    ...(vendor ? [supabase().from("expenses").select(columns).eq("company_id", companyId).eq("incurred_on", date).ilike("vendor", like(vendor)).limit(50)] : []),
  ];
  // The check is a courtesy: if it can't be asked (offline, an older server), the expense saves as it always did.
  const found = await Promise.all(asks.map(async (ask) => ((await ask).data ?? []) as unknown as KnownExpense[])).catch(() => [] as KnownExpense[][]);
  const byId = new Map(found.flat().map((e) => [e.id, e]));
  return [...byId.values()];
}

/** What the form starts as: the expense being edited, or nothing yet. */
const formOf = (expense: Expense | null, today: string) => ({
  vendor: expense?.vendor ?? "",
  category: expense?.category ?? "Materials",
  description: expense?.description ?? "",
  amount: expense ? String(expense.amount) : "",
  tax: expense?.tax_amount != null ? String(expense.tax_amount) : "",
  incurred_on: expense?.incurred_on ?? today,
  reimbursable: expense?.reimbursable ?? false,
  in_line_costs: expense?.in_line_costs ?? false,
});
type Form = ReturnType<typeof formOf>;
type FormKey = keyof Form;

const READ_HINT = msg("Read from the receipt. Check it.");

/** The categories' words (the stored values stay English). */
const CATEGORY_NAMES: Record<string, string> = {
  Materials: msg("Materials"), "Equipment rental": msg("Equipment rental"), "Equipment upkeep": msg("Equipment upkeep"), Fuel: msg("Fuel"), "Dump fees": msg("Dump fees"),
  Subcontractor: msg("Subcontractor"), Permits: msg("Permits"), Supplies: msg("Supplies"), Other: msg("Other"),
};
const qty = (n: number) => new Intl.NumberFormat(intlLocale(), { maximumFractionDigits: 3 }).format(n);

/**
 * Add or edit an expense. With `draft`, a receipt dropped in with others: the form starts from what
 * was read, on its job or the one it names, and saving confirms it. onSaved may return a promise (a
 * refetch): the dialog stays until it's done, so the change is there as it closes.
 */
export function ExpenseDialog({ jobId, expense, draft, onClose, onSaved }: { jobId: string | null; expense: Expense | null; draft?: ExpenseDraft; onClose: () => void; onSaved: () => unknown }) {
  const session = useSession();
  const [f, setF] = useState<Form>(() => formOf(expense, todayIn(session.company.timezone)));
  const [file, setFile] = useState<File | null>(null);
  // Reading what was picked: what came back, and the fields the person has typed in since (left alone).
  const [answer, setAnswer] = useState<ReadAnswer | null>(null);
  const [reading, setReading] = useState<"no" | "reading" | string>("no");
  const typed = useRef(new Set<FormKey>());
  const asked = useRef(0);
  // The office with job costs logs a supplier invoice's lines as the job's materials, and sees what's already in its costs.
  const seesCosts = hasRole(session, "admin", "office") && can(session, "job_costs");
  // A draft with no job: the job it names, or one typed by its number.
  const [pickedJob, setPickedJob] = useState<{ id: string; number: number | null; title: string } | null>(null);
  const [jobNumber, setJobNumber] = useState("");
  const onJobId = jobId ?? draft?.job_id ?? pickedJob?.id ?? null;
  const [choices, setChoices] = useState<number[]>([]);
  const [logMaterials, setLogMaterials] = useState(false);
  // Lines to log although their material already has tickets on the job ("Log it too").
  const [again, setAgain] = useState<boolean[]>([]);

  const set = <K extends FormKey>(k: K, v: Form[K]) => {
    typed.current.add(k);
    setF((prev) => ({ ...prev, [k]: v }));
  };
  const apply = (a: ReadAnswer) => {
    setAnswer(a);
    const r = a.reading;
    setF((prev) => {
      const next = { ...prev };
      const put = <K extends FormKey>(k: K, v: Form[K] | null) => { if (v !== null && v !== "" && !typed.current.has(k)) next[k] = v; };
      put("vendor", r.vendor);
      put("incurred_on", r.date);
      put("amount", r.total !== null ? String(r.total) : null);
      put("tax", r.tax !== null ? String(r.tax) : null);
      put("category", r.category);
      put("description", !prev.description && r.invoice_number ? `Invoice ${r.invoice_number}` : null);
      return next;
    });
    setChoices(a.matches.map((m) => m ?? -1));
    if (a.job && !jobId && !draft?.job_id) setPickedJob((p) => p ?? a.job);
  };
  // A draft starts from what was read for it.
  useEffect(() => {
    if (draft?.read) apply(draft.read);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const pick = (picked: File | null) => {
    setFile(picked);
    // Only a new expense is read: an edited one keeps what the person saved.
    if (!picked || expense || !readingOn(session.company.settings)) return;
    const mine = ++asked.current;
    setReading("reading");
    void readPickedFile(picked, onJobId).then((r) => {
      if (mine !== asked.current) return;
      if ("failed" in r) setReading(r.failed);
      else {
        setReading("no");
        apply(r);
      }
    });
  };

  // A job typed by its number, for a draft that isn't on one.
  const jobLookup = useQuery({
    queryKey: ["jobs", session.company.id, "by-number", jobNumber],
    enabled: !jobId && !draft?.job_id && /^\d{1,9}$/.test(jobNumber),
    queryFn: async () => unwrap(await supabase().from("jobs").select("id, number, title").eq("company_id", session.company.id).eq("number", Number(jobNumber)).neq("status", "archived").maybeSingle()),
  });

  const lines: ReceiptLine[] = answer?.reading.lines ?? [];
  // What the lines were matched against is the job read for: picking another job drops it.
  const readFor = jobId ?? draft?.job_id ?? answer?.job?.id ?? null;
  const candidates = answer && readFor && readFor === onJobId ? answer.candidates : [];

  const amount = Number(f.amount);
  const tax = f.tax.trim() ? Number(f.tax) : null;
  // For the office with job costs, on a job: the crew adding a receipt from a visit isn't asked.
  const onJob = (onJobId !== null || Boolean(expense?.in_line_costs)) && seesCosts;
  // What the job already has logged (the crew's tickets): a material that's there isn't logged twice.
  const loggedBefore = useQuery({
    queryKey: ["job", onJobId, "materials", "logged-before"],
    enabled: onJob && onJobId !== null && lines.length > 0 && candidates.length > 0,
    queryFn: async () => (await everyRow(() => supabase().from("job_materials").select("id, service_id, unit, quantity").eq("job_id", onJobId!))) as unknown as LoggedBefore[],
  });
  // What's logged and how the expense counts, worked out from the form as it stands: never a box
  // ticked along the way and left behind (expenseMaterials.ts).
  const plan = materialsPlan({ lines, candidates, choices, again, before: loggedBefore.data, logMaterials: logMaterials && onJob, amount, ticked: f.in_line_costs, ticket: answer?.reading.invoice_number ?? null });
  const toLog = materialsPlan({ lines, candidates, choices, again, before: loggedBefore.data, logMaterials: true, amount, ticked: false, ticket: answer?.reading.invoice_number ?? null }).toLog;
  // A field filled in from the receipt says so until the person changes it.
  const read = (k: Exclude<ReadField, "lines">) => (answer?.fields.includes(k) && !typed.current.has(k === "date" ? "incurred_on" : k) ? t(READ_HINT) : undefined);
  const save = useMutation({
    meta: { inline: true, success: (saved: boolean) => (!saved ? null : expense ? t("Expense saved") : draft ? t("Receipt saved as an expense") : t("Expense added")) },
    mutationFn: async () => {
      if (!(amount > 0)) throw new Error(t("Enter an amount greater than zero."));
      if (tax !== null && !(tax >= 0 && tax <= amount)) throw new Error(t("Enter the tax as 0 or more, and no more than the amount."));
      if (!jobId && !draft?.job_id && jobNumber && !jobLookup.data) throw new Error(t("There's no job #{number}. Clear it to save the expense without a job.", { number: jobNumber }));
      const receipt_path = file ? await uploadFile(session.company.id, "receipts", file) : draft?.receipt_path ?? expense?.receipt_path ?? null;
      const row = {
        vendor: f.vendor.trim() || null, category: f.category, description: f.description.trim() || null,
        amount: Math.round(amount * 100) / 100, tax_amount: tax === null ? null : Math.round(tax * 100) / 100, incurred_on: f.incurred_on, reimbursable: f.reimbursable, receipt_path,
        // Only the office sets it (below); anyone else's save leaves it as it was.
        in_line_costs: f.in_line_costs,
      };
      const lineItems = lines.length ? lines : null;
      const job = jobId ?? draft?.job_id ?? (jobNumber ? jobLookup.data?.id : pickedJob?.id) ?? null;
      const materials = logMaterials && onJob ? plan.toLog : [];
      const invoiceNumber = answer?.reading.invoice_number?.trim().slice(0, 60) || null;
      // The same receipt twice: asked about before it's saved again (among the expenses this person can see).
      if (!expense) {
        const question = sameReceiptQuestion(lookalikes({ vendor: row.vendor, total: row.amount, date: row.incurred_on, invoice_number: invoiceNumber }, await knownExpenses(session.company.id, row.vendor, row.incurred_on, invoiceNumber)));
        if (question && !(await confirm(question))) return false;
      }
      // Part of it in the job's line items (what's logged against the estimate) and part not: saved as two, so each counts once.
      const inLines = logMaterials && onJob && !f.in_line_costs ? plan.inLineAmount : null;
      // An expense with no job (Finance → Profit lists them) can be put on one here: its Job # is asked. One opened from its job stays there.
      if (expense) unwrap(await supabase().from("expenses").update(jobId || !job ? row : { ...row, job_id: job }).eq("id", expense.id));
      else if (draft || materials.length || inLines) {
        // The expense, the materials and the draft's removal at once (save_read_expense).
        unwrap(await supabase().rpc("save_read_expense", {
          p_expense: { ...row, line_items: lineItems, company_id: session.company.id, job_id: job, invoice_number: invoiceNumber, ...(inLines === null ? {} : { in_line_amount: inLines }) } as never,
          p_materials: materials as never,
          p_draft: draft?.id,
        }));
      } else unwrap(await supabase().from("expenses").insert({ ...row, line_items: lineItems as never, company_id: session.company.id, job_id: job, invoice_number: invoiceNumber }));
      return true;
    },
    onSuccess: async (saved) => {
      // Went back from "this looks like a receipt that's already in": the form stays as it was.
      if (!saved) return;
      await onSaved();
      onClose();
    },
  });
  const suggested = answer?.job && pickedJob?.id === answer.job.id && !jobNumber ? answer.job : null;

  return (
    <Dialog open onClose={onClose} title={expense ? t("Edit expense") : draft ? t("Check receipt") : t("Add expense")}>
      <form onSubmit={(e: FormEvent) => { e.preventDefault(); save.mutate(); }}>
        {reading === "reading" && (
          <div className="callout callout-info" role="status"><span className="spinner" style={{ width: 14, height: 14 }} aria-hidden="true" /><span className="grow small" style={{ fontWeight: 400 }}>{t("Reading the receipt. You can start filling it in.")}</span></div>
        )}
        {reading !== "no" && reading !== "reading" && <p className="muted small" role="status" style={{ margin: 0 }}>{t("Couldn't read it: {reason}. Fill it in by hand.", { reason: translateError(getLocale(), reading).replace(/\.$/, "") })}</p>}
        {draft?.status === "failed" && !answer && <p className="muted small" style={{ margin: 0 }}>{draft.error ? t("This one couldn't be read: {reason}. Fill it in by hand.", { reason: translateError(getLocale(), draft.error).replace(/\.$/, "") }) : t("This one couldn't be read. Fill it in by hand.")}</p>}
        {answer && answer.fields.length > 0 && (
          <div className="callout callout-info" role="status">
            <Icon name="sparkle" size={16} />
            <span className="grow small" style={{ fontWeight: 400 }}>{t("Read from the receipt: {fields}. Check them before you save.", { fields: readFieldsText(answer.fields) })}</span>
          </div>
        )}
        {answer && answer.problems.length > 0 && (
          <div className="callout callout-warning" role="status">
            <Icon name="alert" size={16} />
            <div className="grow small stack-sm" style={{ fontWeight: 400 }}>{answer.problems.map((p) => <span key={p}>{translateError(getLocale(), p)}</span>)}</div>
          </div>
        )}
        <div className="form-grid">
          <Field label={t("Amount")} requiredMessage={t("Enter what it cost.")} hint={read("amount")}><span className="input-group"><span className="addon">$</span><input className="input" inputMode="decimal" style={{ paddingLeft: 22 }} value={f.amount} onChange={(e) => set("amount", e.target.value.replace(/[^0-9.]/g, ""))} required autoFocus /></span></Field>
          <Field label={t("Date")} hint={read("date")}><input className="input" type="date" value={f.incurred_on} onChange={(e) => set("incurred_on", e.target.value)} required /></Field>
          <Field label={t("Vendor")} optional hint={read("vendor")}><input className="input" value={f.vendor} onChange={(e) => set("vendor", e.target.value)} maxLength={120} placeholder={t("Home Depot, quarry…")} /></Field>
          <Field label={t("Category")} hint={read("category")}>
            <Select className="select" value={f.category} onChange={(e) => set("category", e.target.value)}>
              {EXPENSE_CATEGORIES.map((c) => <option key={c} value={c}>{t(CATEGORY_NAMES[c] ?? c)}</option>)}
            </Select>
          </Field>
          <Field label={t("Tax")} optional hint={read("tax") ?? t("Included in the amount.")}><span className="input-group"><span className="addon">$</span><input className="input" inputMode="decimal" style={{ paddingLeft: 22 }} value={f.tax} onChange={(e) => set("tax", e.target.value.replace(/[^0-9.]/g, ""))} /></span></Field>
          {!jobId && !draft?.job_id && (
            <Field label={t("Job #")} optional hint={suggested ? t("Suggested: {job}", { job: suggestedJobText(suggested) }) : jobLookup.data ? jobLookup.data.title : jobNumber && jobLookup.isFetched ? t("No job #{number}", { number: jobNumber }) : pickedJob ? pickedJob.title : t("Leave empty for a cost that isn't a job's.")}>
              <input className="input" inputMode="numeric" value={jobNumber || (pickedJob?.number != null ? String(pickedJob.number) : "")} onChange={(e) => { setPickedJob(null); setJobNumber(e.target.value.replace(/[^0-9]/g, "")); }} />
            </Field>
          )}
        </div>
        <Field label={t("Description")} optional><input className="input" value={f.description} onChange={(e) => set("description", e.target.value)} maxLength={300} /></Field>
        {lines.length > 0 && (
          <div className="stack-sm">
            <strong className="small">{t("Lines on the invoice")}</strong>
            <div className="card">
              {lines.map((l, i) => {
                const lineTotal = lineAmount(l);
                return (
                  <div key={i} className="card-row" style={{ flexWrap: "wrap" }}>
                    <span className="grow small">
                      {l.description}
                      <span className="muted" style={{ display: "block" }}>
                        {[l.quantity !== null ? `${qty(l.quantity)}${l.unit ? ` ${l.unit}` : ""}` : null, l.unit_price !== null ? t("at {price}", { price: formatMoneyCents(l.unit_price) }) : null].filter(Boolean).join(" ")}
                      </span>
                    </span>
                    {lineTotal !== null && <span className="small tabular">{formatMoneyCents(lineTotal)}</span>}
                    {onJob && candidates.length > 0 && (
                      <Select className="select" style={{ width: "auto", maxWidth: 220 }} aria-label={t("Log {line} as", { line: l.description })} value={choices[i] ?? -1} onChange={(e) => setChoices(choices.map((c, n) => (n === i ? Number(e.target.value) : c)))}>
                        <option value={-1}>{t("Not a material on this job")}</option>
                        {candidates.map((c, n) => <option key={n} value={n}>{c.name} ({c.unit}){c.estimated ? "" : t(" · price list")}</option>)}
                      </Select>
                    )}
                    {onJob && logMaterials && <LineAlreadyLogged plan={plan.lines[i]} again={Boolean(again[i])} onAgain={(on) => setAgain(lines.map((_, n) => (n === i ? on : Boolean(again[n]))))} />}
                  </div>
                );
              })}
            </div>
            {onJob && candidates.length > 0 && (
              <label className="checkbox" style={{ alignItems: "flex-start" }}>
                <input type="checkbox" checked={logMaterials} disabled={!toLog.length} onChange={(e) => setLogMaterials(e.target.checked)} />
                <span>
                  {t.plural(toLog.length, { one: "Also log the matched line as materials used on this job", other: "Also log the {count} matched lines as materials used on this job" })}
                  <span className="muted small" style={{ display: "block" }}>{t("Each counts in job costing at the line item's cost, in place of the estimate. The job's line items don't change.")}</span>
                </span>
              </label>
            )}
          </div>
        )}
        <label className="dropzone" style={{ padding: 14 }}>
          <Icon name="camera" size={20} />
          <span className="small strong">{file ? file.name : draft ? draft.file_name ?? t("The receipt") : expense?.receipt_path ? t("Replace the receipt photo") : t("Add a receipt photo")}</span>
          {!expense && !draft && readingOn(session.company.settings) && !file && <span className="small muted">{t("It's read and fills in the form for you to check.")}</span>}
          <input type="file" accept="image/*,application/pdf" capture="environment" className="sr-only" onChange={(e) => pick(e.target.files?.[0] ?? null)} />
        </label>
        <label className="checkbox"><input type="checkbox" checked={f.reimbursable} onChange={(e) => set("reimbursable", e.target.checked)} /> {t("Paid with my own money (reimburse me)")}</label>
        {onJob && (
          <label className="checkbox" style={{ alignItems: "flex-start" }}>
            <input type="checkbox" checked={f.in_line_costs} onChange={(e) => set("in_line_costs", e.target.checked)} />
            <span>
              {t("Already in the job's line item costs")}
              <span className="muted small" style={{ display: "block" }}>{t("For the supplier's invoice for materials the estimate covers. Job costing keeps the line items' cost and doesn't count this again.")}</span>
            </span>
          </label>
        )}
        {onJob && lines.length > 0 && <CostingNote plan={plan} logMaterials={logMaterials} ticked={f.in_line_costs} />}
        <FormError error={save.error} />
        <div className="form-actions">
          <FormChecks />
          <Button onClick={onClose}>{t("Cancel")}</Button>
          {/* With a receipt photo it uploads, which is slow anyway. */}
          <Button type="submit" variant="primary" loading={save.isPending} slowHint={file ? false : undefined}>{expense ? t("Save") : draft ? t("Save expense") : t("Add expense")}</Button>
        </div>
      </form>
    </Dialog>
  );
}
