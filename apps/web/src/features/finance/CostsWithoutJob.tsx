/**
 * "Costs that aren't on a job" on Finance → Profit, beside the receipts card: the expenses saved
 * with no job (fuel, a tool, a supplier's bill for the yard). Add expense and Check receipt both
 * invite one ("Leave empty for a cost that isn't a job's"), and until this list nothing showed them
 * again: every other list of expenses is a job's or a piece of equipment's. Here each can be opened
 * and changed (or put on a job after all), marked reimbursed and deleted, by the office, who could
 * always do those to an expense.
 */
import { TRASH_DAYS } from "@jobly/core/drive";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { confirm } from "@/components/ui/Confirm";
import { Icon } from "@/components/ui/Icon";
import { Menu } from "@/components/ui/Menu";
import { Skeleton } from "@/components/ui/Skeleton";
import { EmptyState, ErrorState } from "@/components/ui/States";
import { supabase, unwrap } from "@/lib/api";
import { signedUrls } from "@/lib/files";
import { formatDate, formatMoneyCents } from "@/lib/format";
import { everyRow } from "@/lib/paging";
import { useSession } from "@/lib/session";
import { ExpenseDialog } from "../jobs/ExpensesCard";

export interface LooseExpense {
  id: string;
  vendor: string | null;
  description: string | null;
  category: string | null;
  amount: number;
  tax_amount: number | null;
  incurred_on: string;
  receipt_path: string | null;
  reimbursable: boolean;
  reimbursed_at: string | null;
  in_line_costs: boolean;
  line_items: unknown;
}

export const costsWithoutJobKey = (companyId: string) => ["expenses-without-job", companyId];

/** How many show before "Show all". */
export const FIRST_SHOWN = 10;

/** "12 costs · $1,840.25 · 2 to reimburse": what the card says under its title. */
export function looseSummary(rows: ReadonlyArray<Pick<LooseExpense, "amount" | "reimbursable" | "reimbursed_at">>): string {
  if (!rows.length) return "Fuel, tools and other costs saved without a job";
  const owed = rows.filter((r) => r.reimbursable && !r.reimbursed_at).length;
  const total = rows.reduce((sum, r) => sum + Math.round(Number(r.amount) * 100), 0) / 100;
  return [`${rows.length} ${rows.length === 1 ? "cost" : "costs"}`, formatMoneyCents(total), owed ? `${owed} to reimburse` : null].filter(Boolean).join(" · ");
}

/** What a row says under its name: its category, description and date, and whether it's owed back. */
export function looseDetail(e: Pick<LooseExpense, "category" | "description" | "incurred_on" | "reimbursable" | "reimbursed_at">): string {
  return [e.category, e.description, formatDate(e.incurred_on), e.reimbursable ? (e.reimbursed_at ? "reimbursed" : "to reimburse") : null].filter(Boolean).join(" · ");
}

export function useCostsWithoutJob(enabled = true) {
  const session = useSession();
  return useQuery({
    queryKey: costsWithoutJobKey(session.company.id),
    enabled,
    queryFn: async () => {
      // Every one, newest first: years of them can pass what one request brings.
      const rows = (await everyRow(
        () => supabase().from("expenses").select("id, vendor, description, category, amount, tax_amount, incurred_on, receipt_path, reimbursable, reimbursed_at, in_line_costs, line_items").eq("company_id", session.company.id).is("job_id", null).is("equipment_id", null),
        { order: { column: "incurred_on", ascending: false } },
      )) as unknown as LooseExpense[];
      return rows;
    },
  });
}

export function CostsWithoutJob({ onChanged }: { onChanged?: () => unknown }) {
  const session = useSession();
  const queryClient = useQueryClient();
  const costs = useCostsWithoutJob();
  const [editing, setEditing] = useState<LooseExpense | "new" | null>(null);
  const [all, setAll] = useState(false);
  const refresh = async () => {
    await queryClient.invalidateQueries({ queryKey: costsWithoutJobKey(session.company.id) });
    await onChanged?.();
  };
  const reimburse = useMutation({
    meta: { success: "Marked reimbursed" },
    mutationFn: async (id: string) => unwrap(await supabase().from("expenses").update({ reimbursed_at: new Date().toISOString() }).eq("id", id)),
    onSuccess: refresh,
  });
  const remove = useMutation({
    meta: { success: "Expense deleted" },
    mutationFn: async (id: string) => unwrap(await supabase().from("expenses").delete().eq("id", id)),
    onSuccess: refresh,
  });
  // The receipt opens in a new tab on a link that's made as it's asked for.
  const openReceipt = async (path: string) => {
    const url = (await signedUrls([path]).catch(() => ({}) as Record<string, string>))[path];
    if (url) window.open(url, "_blank", "noopener");
  };

  const rows = costs.data ?? [];
  const shown = all ? rows : rows.slice(0, FIRST_SHOWN);
  return (
    <div className="stack-sm">
      <div className="row" style={{ justifyContent: "space-between", gap: 8, flexWrap: "wrap" }}>
        <span className="muted small">{costs.data ? looseSummary(rows) : " "}</span>
        <Button size="sm" icon="plus" onClick={() => setEditing("new")}>Add a cost</Button>
      </div>
      {costs.error ? (
        <ErrorState error={costs.error} onRetry={() => costs.refetch()} />
      ) : (
        <div className="card">
          {costs.isPending && [0, 1].map((i) => <div key={i} className="card-row"><span className="grow stack-sm"><Skeleton width="40%" /><Skeleton width="25%" height={10} /></span><Skeleton width={70} /></div>)}
          {costs.data && !rows.length && <EmptyState inline title="No costs without a job">An expense saved with its Job # left empty shows here</EmptyState>}
          {shown.map((e) => (
            <div key={e.id} className="card-row">
              <span className="n-icon" style={{ width: 36, height: 36, borderRadius: 8, display: "grid", placeItems: "center", background: "var(--fill-2)", color: "var(--text-3)", flex: "none" }}><Icon name="receipt" size={18} /></span>
              <button type="button" className="grow link-btn" style={{ textAlign: "left", color: "inherit" }} onClick={() => setEditing(e)} aria-label={`Open ${e.vendor || e.category || "expense"}, ${formatMoneyCents(e.amount)}`}>
                <strong style={{ display: "block" }}>{e.vendor || e.category || "Expense"}</strong>
                <span className="muted small" style={{ display: "block", fontWeight: 400 }}>{looseDetail(e)}</span>
              </button>
              <strong className="tabular">{formatMoneyCents(e.amount)}</strong>
              <Menu
                triggerClassName="btn btn-sm btn-ghost btn-icon"
                label="Expense actions"
                items={[
                  { label: "Open and change", icon: "edit", onSelect: () => setEditing(e) },
                  { label: "Open the receipt", icon: "receipt", hidden: !e.receipt_path, onSelect: () => void openReceipt(e.receipt_path!) },
                  { label: "Mark reimbursed", icon: "check", hidden: !e.reimbursable || Boolean(e.reimbursed_at), onSelect: () => reimburse.mutate(e.id) },
                  {
                    label: "Delete",
                    icon: "trash",
                    danger: true,
                    onSelect: async () => {
                      const ok = await confirm({
                        title: "Delete this expense?",
                        body: `${e.vendor || e.category || "Expense"}, ${formatMoneyCents(e.amount)} on ${formatDate(e.incurred_on)}.${e.receipt_path ? ` Its receipt goes to the Trash for ${TRASH_DAYS} days.` : ""}`,
                        confirmLabel: "Delete",
                        danger: true,
                      });
                      if (ok) remove.mutate(e.id);
                    },
                  },
                ]}
              />
            </div>
          ))}
          {rows.length > FIRST_SHOWN && (
            <div className="card-row"><Button size="sm" variant="ghost" onClick={() => setAll(!all)}>{all ? "Show fewer" : `Show all ${rows.length}`}</Button></div>
          )}
        </div>
      )}
      {editing && <ExpenseDialog jobId={null} expense={editing === "new" ? null : editing} onClose={() => setEditing(null)} onSaved={refresh} />}
    </div>
  );
}
