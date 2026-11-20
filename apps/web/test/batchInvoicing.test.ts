/**
 * Batch invoicing more jobs than the server takes in one call (features/invoices/batch.ts): the
 * picked jobs go 50 at a time, one group after another, every group's results end up in one list,
 * a group that fails is reported without stopping the rest, and the reasons are said once each.
 */
import { describe, expect, it, vi } from "vitest";
import { BATCH_CHUNK, failureText, groupFailed, invoiceInChunks, type BatchResult } from "../src/features/invoices/batch";

const jobs = (n: number) => Array.from({ length: n }, (_, i) => ({ id: `job-${i + 1}`, number: i + 1 }));
const made = (ids: string[]): { results: BatchResult[] } => ({ results: ids.map((id) => ({ job_id: id, number: Number(id.slice(4)), ok: true, invoice_id: `inv-${id}`, sent: false })) });

describe("invoicing the picked jobs in groups", () => {
  it("sends 150 jobs as three calls of 50, in order, one after another", async () => {
    let running = 0;
    const post = vi.fn(async (ids: string[]) => {
      expect(++running).toBe(1);
      await Promise.resolve();
      running--;
      return made(ids);
    });
    const progress: Array<[number, number]> = [];
    const results = await invoiceInChunks(jobs(150), post, (invoiced, total) => progress.push([invoiced, total]));
    expect(BATCH_CHUNK).toBe(50);
    expect(post.mock.calls.map((c) => c[0].length)).toEqual([50, 50, 50]);
    expect(post.mock.calls.flatMap((c) => c[0])).toEqual(jobs(150).map((j) => j.id));
    expect(results).toHaveLength(150);
    expect(results.every((r) => r.ok)).toBe(true);
    expect(progress).toEqual([[50, 150], [100, 150], [150, 150]]);
  });

  it("sends a last group that's smaller, and one call for 50 or fewer", async () => {
    const post = vi.fn(async (ids: string[]) => made(ids));
    await invoiceInChunks(jobs(120), post);
    expect(post.mock.calls.map((c) => c[0].length)).toEqual([50, 50, 20]);
    post.mockClear();
    await invoiceInChunks(jobs(50), post);
    expect(post.mock.calls.map((c) => c[0].length)).toEqual([50]);
  });

  it("carries on past a group that fails, and says which jobs it was and why", async () => {
    const post = vi.fn(async (ids: string[]) => {
      if (ids[0] === "job-51") throw new Error("The server took too long.");
      return made(ids);
    });
    const progress: number[] = [];
    const results = await invoiceInChunks(jobs(150), post, (invoiced) => progress.push(invoiced));
    expect(post).toHaveBeenCalledTimes(3);
    expect(results.filter((r) => r.ok).map((r) => r.number)).toEqual([...jobs(50).map((j) => j.number), ...jobs(150).slice(100).map((j) => j.number)]);
    const failed = results.filter((r) => !r.ok);
    expect(failed.map((r) => r.number)).toEqual(jobs(100).slice(50).map((j) => j.number));
    expect(new Set(failed.map((r) => r.error))).toEqual(new Set([groupFailed("The server took too long.")]));
    // The failed group's jobs aren't counted as invoiced.
    expect(progress).toEqual([50, 50, 100]);
  });

  it("keeps the server's own word on each job: one skipped for autopay, a monthly job's months", async () => {
    const post = async (ids: string[]): Promise<{ results: BatchResult[] }> => ({
      results: ids.flatMap((id): BatchResult[] =>
        id === "job-2" ? [{ job_id: id, number: 2, ok: false, error: "This job is charged automatically tonight." }]
          : id === "job-3" ? [{ job_id: id, number: 3, month: "2026-10-01", ok: true, invoice_id: "a" }, { job_id: id, number: 3, month: "2026-11-01", ok: true, invoice_id: "b" }]
            : made([id]).results),
    });
    const progress: number[] = [];
    const results = await invoiceInChunks(jobs(3), post, (invoiced) => progress.push(invoiced));
    expect(results).toHaveLength(4);
    // Jobs with an invoice, not invoices: the monthly job counts once.
    expect(progress).toEqual([2]);
  });
});

describe("saying why jobs weren't invoiced", () => {
  it("names one job with its reason", () => {
    expect(failureText([{ number: 12, error: "This job is charged automatically tonight." }])).toBe("Job #12: This job is charged automatically tonight.");
  });

  it("says a reason once for all the jobs it goes for, naming the first five", () => {
    const group = jobs(50).map((j) => ({ number: j.number, error: groupFailed("You're offline.") }));
    expect(failureText([...group, { number: 77, error: "There are no completed visits waiting to be invoiced" }])).toBe(
      "Jobs #1, #2, #3, #4, #5 and 45 more: You're offline. That group didn't finish, so look in Drafts before invoicing these again. Job #77: There are no completed visits waiting to be invoiced.",
    );
  });

  it("still says something for a job with no number or reason", () => {
    expect(failureText([{ number: null, error: undefined }])).toBe("Job #?: Not invoiced.");
  });
});
