/**
 * Who the Send dialog sends a quote or invoice to: the people ticked (the client, their contacts)
 * and any address typed in, as one list for the server, which checks each again. Kept apart from
 * the dialog so it can be tested without it.
 */
import { MAX_RECIPIENTS, uniqueAddresses, type SendChoice } from "@jobly/core/recipients";

export type SendChannel = "email" | "sms";

/** What GET /quotes/:id/recipients (or /invoices/:id/recipients) answers. */
export interface SendChoices {
  email: SendChoice[];
  sms: SendChoice[];
  /** The company sends to contacts ticked for reminders (Settings → Client notifications). */
  contacts_on: boolean;
  max: number;
}

/**
 * What the dialog offers when the server can't say (it's offline, or older than this page): the
 * client's own email and phone, as the dialog always had them.
 */
export function ownChoices(client: { email: string | null; phone: string | null; textsOffSince?: string | null }): SendChoices {
  const own = (to: string | null, blocked = false): SendChoice[] =>
    to?.trim() ? [{ to: to.trim(), name: "The client", contact_id: null, ticked: !blocked, ...(blocked ? { blocked: "Texts off" } : {}) }] : [];
  return { email: own(client.email), sms: own(client.phone, Boolean(client.textsOffSince)), contacts_on: false, max: MAX_RECIPIENTS };
}

/** The addresses or numbers typed into "Someone else": several, apart by commas, semicolons or new lines (or spaces, for emails). */
export function typedAddresses(channel: SendChannel, typed: string): string[] {
  return typed.split(channel === "email" ? /[\s,;]+/ : /[,;\n]+/).map((part) => part.trim()).filter(Boolean);
}

/** Everyone a send goes to: those ticked, then those typed, each once. */
export function sendList(channel: SendChannel, ticked: readonly string[], typed: string): string[] {
  return uniqueAddresses(channel, [...ticked, ...typedAddresses(channel, typed)]);
}

const isEmail = (value: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value);
const isPhone = (value: string) => value.replace(/\D/g, "").length >= 7;

/** Why the list can't be sent to as it is, in words for under the field; null when it can. */
export function sendListProblem(channel: SendChannel, list: readonly string[], max = MAX_RECIPIENTS): string | null {
  if (!list.length) return channel === "email" ? "Pick who to email, or add an address." : "Pick who to text, or add a number.";
  if (list.length > max) return `Send it to ${max} people at most.`;
  const wrong = list.find((to) => (channel === "email" ? !isEmail(to) : !isPhone(to)));
  return wrong ? (channel === "email" ? `${wrong} isn't an email address.` : `${wrong} isn't a phone number.`) : null;
}

/**
 * The body for POST /quotes/:id/send (or /invoices/:id/send). `to` is the first of them, for a
 * server from before it took a list: that one sends to it alone, which is what it always did.
 */
export function sendPayload(input: { channel: SendChannel | "link"; list: readonly string[]; subject: string; message: string }) {
  const message = input.message.trim() || undefined;
  if (input.channel === "link") return { channel: "link" as const, message };
  return {
    channel: input.channel,
    to: input.list[0],
    recipients: [...input.list],
    subject: input.channel === "email" ? input.subject.trim() || undefined : undefined,
    message,
  };
}

/** "ana@example.com", "ana@example.com and bo@example.com", "ana@example.com, bo@example.com and cy@example.com". */
export function listWords(list: readonly string[]): string {
  return list.length <= 1 ? (list[0] ?? "") : `${list.slice(0, -1).join(", ")} and ${list[list.length - 1]}`;
}
