/**
 * What the job page's Create invoice dialog offers for a job, and which choice it opens on. The
 * database decides the same when the invoice is made (create_invoice_for_job).
 */
import { formatMoneyCents } from "@/lib/format";

export type InvoiceKind = "standard" | "deposit" | "progress" | "visits" | "retainage";

export interface InvoiceJob {
  id: string;
  contract_total: number;
  /** What the quote asked for up front; 0 when it asked for none. */
  deposit: number;
  /**
   * The job's deposit invoice, once it has one that isn't void: made by hand here, or as the client
   * approved the quote in the Client Hub (hub_deposit_invoice).
   */
  depositInvoice: number | null;
  /** Deposits and progress invoices so far (not void), before tax. */
  billed: number;
  uninvoicedVisits: number;
  kind: string;
  /** A recurring job at a fixed price, whose invoice is its lines once. */
  fixed?: boolean;
  /**
   * A job billed by the visit (core billsByVisit), the only kind Completed visits is for: on any
   * other it would bill the whole job once for each visit, and the database refuses it.
   */
  byVisit: boolean;
  retainageHeld: number;
  /** A one-off job's final invoice, once it has one that isn't void. */
  finalInvoice: number | null;
}

export interface InvoiceChoice {
  kind: InvoiceKind;
  title: string;
  body: string;
}

/** The choice the dialog opens on: what the job is most likely to need next. */
export function firstInvoiceKind(job: InvoiceJob): InvoiceKind {
  if (job.kind === "recurring") return job.byVisit ? "visits" : "standard";
  if (!job.finalInvoice) return "standard";
  return job.retainageHeld > 0.005 ? "retainage" : "progress";
}

/**
 * The amount a choice's field starts with: the deposit the quote asked for, until it's been
 * invoiced (a second one is never filled in for them). Empty for everything else.
 */
export const startingAmount = (job: InvoiceJob, kind: InvoiceKind) => (kind === "deposit" && job.deposit && !job.depositInvoice ? String(job.deposit) : "");

/** The choices shown, in order. */
export function invoiceChoices(job: InvoiceJob): InvoiceChoice[] {
  const visits = job.uninvoicedVisits;
  const all: Array<InvoiceChoice & { hidden?: boolean }> = [
    {
      kind: "standard",
      title: job.fixed ? "The job's price" : "Final invoice",
      body: job.fixed ? "All the job's line items, once."
        : job.finalInvoice ? `Already created: invoice #${job.finalInvoice}. Void it to bill the job again.`
          : job.billed ? `All line items, less ${formatMoneyCents(job.billed)} already billed as deposits or progress.`
            : "All the job's line items.",
    },
    {
      kind: "visits",
      title: "Completed visits",
      body: visits ? `${visits} completed ${visits === 1 ? "visit isn't" : "visits aren't"} invoiced yet.` : "No completed visits are waiting to be invoiced.",
      hidden: !job.byVisit || (job.kind !== "recurring" && !visits),
    },
    {
      kind: "deposit",
      title: "Deposit",
      body: job.depositInvoice ? `Deposit already invoiced (#${job.depositInvoice}). Enter an amount only to bill another.`
        : job.deposit ? `The quote asked for ${formatMoneyCents(job.deposit)}.`
          : "Bill an amount up front.",
    },
    { kind: "progress", title: "Progress payment", body: "Bill part of the contract now (a pay application).", hidden: Boolean(job.finalInvoice) },
    { kind: "retainage", title: "Retainage", body: `Bill the ${formatMoneyCents(job.retainageHeld)} held back on earlier invoices.`, hidden: !(job.retainageHeld > 0.005) },
  ];
  return all.filter((c) => !c.hidden).map(({ kind, title, body }) => ({ kind, title, body }));
}
