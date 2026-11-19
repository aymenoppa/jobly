/**
 * Batch invoicing from the Invoices page (InvoiceTools.tsx BatchDialog): the picked jobs go to the
 * server a group at a time (POST /invoices/batch takes 50), one group after another, and what
 * happened to each job comes back in one list, however many groups it took.
 */
import { errorMessage } from "@/lib/errors";

/** The most jobs one call takes. */
export const BATCH_CHUNK = 50;

/** What the server did with a job (services/sales.ts invoiceJobs): a monthly job has one for each month due. */
export interface BatchResult {
  job_id: string;
  number: number | null;
  month?: string;
  ok: boolean;
  invoice_id?: string;
  sent?: boolean;
  error?: string;
}

/** Said for each job of a group whose request failed: the server may have made some of their invoices before it did. */
export const groupFailed = (reason: string) => `${reason.replace(/[.\s]+$/, "")}. That group didn't finish, so look in Drafts before invoicing these again.`;

/**
 * Sends the picked jobs BATCH_CHUNK at a time and puts each group's results together, in the order
 * the jobs were picked. A group whose request fails doesn't stop the ones after it: each of its
 * jobs says it wasn't invoiced, and why. `onProgress` hears, after each group, how many jobs have
 * their invoice so far.
 */
export async function invoiceInChunks(
  jobs: ReadonlyArray<{ id: string; number: number | null }>,
  post: (jobIds: string[]) => Promise<{ results: BatchResult[] }>,
  onProgress?: (invoiced: number, total: number) => void,
): Promise<BatchResult[]> {
  const results: BatchResult[] = [];
  const invoiced = new Set<string>();
  for (let i = 0; i < jobs.length; i += BATCH_CHUNK) {
    const chunk = jobs.slice(i, i + BATCH_CHUNK);
    try {
      const r = await post(chunk.map((j) => j.id));
      results.push(...r.results);
      for (const one of r.results) if (one.ok) invoiced.add(one.job_id);
    } catch (e) {
      const error = groupFailed(errorMessage(e));
      results.push(...chunk.map((j) => ({ job_id: j.id, number: j.number, ok: false, error })));
    }
    onProgress?.(invoiced.size, jobs.length);
  }
  return results;
}

const MAX_NUMBERS = 5;

/**
 * Why the jobs that failed weren't invoiced, a sentence for each reason with the jobs it goes for:
 * "Job #12: This job is charged automatically tonight." or "Jobs #14, #15 and 48 more: …", so a
 * group that failed for one reason says it once.
 */
export function failureText(failed: ReadonlyArray<Pick<BatchResult, "number" | "error">>): string {
  const byReason = new Map<string, string[]>();
  for (const f of failed) {
    const reason = (f.error ?? "Not invoiced").replace(/[.\s]+$/, "");
    byReason.set(reason, [...(byReason.get(reason) ?? []), `#${f.number ?? "?"}`]);
  }
  return [...byReason]
    .map(([reason, numbers]) => {
      const shown = numbers.slice(0, MAX_NUMBERS).join(", ");
      const more = numbers.length - MAX_NUMBERS;
      return `${numbers.length === 1 ? "Job" : "Jobs"} ${shown}${more > 0 ? ` and ${more} more` : ""}: ${reason}.`;
    })
    .join(" ");
}
