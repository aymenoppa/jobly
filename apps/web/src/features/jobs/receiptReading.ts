/**
 * Reading receipts and supplier invoices (apps/api/src/routes/receipts.ts): the company's switch, a
 * file sent to be read, and what comes back. Off, or when reading fails or takes too long, the form
 * is filled in by hand as it always was: nothing here throws at the person adding an expense.
 */
import type { MaterialCandidate, ReadField, ReceiptReading } from "@jobly/core/receipts";
import { api } from "@/lib/api";
import { ApiError } from "@/lib/errors";
import { base64Of, compressImage } from "@/lib/files";
import { msg, t } from "@/lib/i18n";
import { OLD_SERVER } from "./receiptDraftWords";

/** What the server sends back for one file. */
export interface ReadAnswer {
  reading: ReceiptReading;
  fields: ReadField[];
  problems: string[];
  /** The job it names, among the person's (only when it wasn't read for a job already). */
  job: { id: string; number: number | null; title: string; why: "job_number" | "po_number" | "address" } | null;
  /** What its lines can be logged as on the job (the office with job costs), and the one each line seems to be. */
  candidates: MaterialCandidate[];
  matches: Array<number | null>;
}

/** The company's switch (settings.receipt_reading), which only the server turns on. */
export const readingOn = (settings: unknown) => (settings as { receipt_reading?: unknown } | null)?.receipt_reading === true;

/** How long the form waits for a reading before it's left to be filled in by hand. */
const READ_WAIT_MS = 60_000;

/** Read a picked file: what it says, or null (off, offline, too slow, or it couldn't be read). */
export async function readPickedFile(file: File, jobId: string | null): Promise<ReadAnswer | { failed: string }> {
  try {
    // A phone photo shrunk as it would be uploaded: Claude reads it as well, and it travels faster.
    const body = file.type.startsWith("image/") ? await compressImage(file, 2000, 0.85) : file;
    const ask = api.post<ReadAnswer>("/receipts/read", { file: await base64Of(body), job_id: jobId });
    const slow = new Promise<never>((_, reject) => setTimeout(() => reject(new Error(t("Reading it took too long. Fill it in by hand."))), READ_WAIT_MS));
    return await Promise.race([ask, slow]);
  } catch (error) {
    // A server from before reading has no such address: said, rather than "Not found".
    if (error instanceof ApiError && (error.status === 404 || error.status === 405)) return { failed: OLD_SERVER };
    return { failed: error instanceof Error ? error.message : msg("It couldn't be read. Fill it in by hand.") };
  }
}

const NAMES: Record<ReadField, string> = { vendor: msg("vendor"), date: msg("date"), amount: msg("total"), tax: msg("tax"), category: msg("category"), lines: msg("line items") };
/** "vendor, date, total and tax" */
export function readFieldsText(fields: readonly ReadField[]): string {
  const names = fields.map((f) => t(NAMES[f]));
  return names.length > 1 ? t("{list} and {last}", { list: names.slice(0, -1).join(", "), last: names.at(-1) }) : names[0] ?? "";
}

const WHY: Record<NonNullable<ReadAnswer["job"]>["why"], string> = { job_number: msg("Job #{number} {title} (by its job number)"), po_number: msg("Job #{number} {title} (by its PO number)"), address: msg("Job #{number} {title} (by its address)") };
/** "Job #1042 Birch drive (by its address)" */
export const suggestedJobText = (job: NonNullable<ReadAnswer["job"]>) => t(WHY[job.why], { number: job.number ?? "?", title: job.title });
