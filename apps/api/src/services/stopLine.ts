/**
 * Telling people how to stop texts. Twilio's messaging policy: "The initial message that you send
 * to a recipient needs to include the following language: 'Reply STOP to unsubscribe,' or the
 * equivalent using another standard opt-out keyword". So the first text Jobly writes to a number
 * for a company ends with "Reply STOP to opt out." (core addStopLine), and so does every
 * promotional one (a text a business added to Re-engage past clients or Win back lost quotes).
 *
 * Which numbers have been told is kept for each company (public.sms_told), so the line goes once:
 * a reminder isn't a segment longer every time. Review asks always carry the line already
 * (services/reviews.ts), and count as telling. A text someone types in Messages is theirs, sent as
 * typed, and doesn't count.
 *
 * If the list can't be read the line is added anyway, and if it can't be written the next text
 * carries the line again: either way nobody goes untold.
 */
import { addStopLine } from "@jobly/core/marketing";
import { phoneMatchKey } from "@jobly/core/recipients";
import type { SendResult } from "../lib/notify";
import type { Db } from "../lib/supabase";

/** Whether a text of the company's has already told this number how to stop. */
async function wasTold(admin: Db, companyId: string, to: string): Promise<boolean> {
  const key = phoneMatchKey(to);
  if (!key) return false;
  const { data, error } = await admin.from("sms_told").select("phone_key").eq("company_id", companyId).eq("phone_key", key).limit(1);
  if (error) {
    console.error(`Couldn't read which numbers were told how to stop texts: ${error.message}`);
    return false;
  }
  return Boolean(data?.length);
}

/** A text that said how to stop went to this number: remembered, so the next one doesn't repeat it. */
export async function noteTold(admin: Db, companyId: string, to: string): Promise<void> {
  const key = phoneMatchKey(to);
  if (!key) return;
  const { error } = await admin.from("sms_told").upsert({ company_id: companyId, phone_key: key }, { onConflict: "company_id,phone_key", ignoreDuplicates: true });
  if (error) console.error(`Couldn't note a number as told how to stop texts: ${error.message}`);
}

/**
 * Sends a text Jobly wrote to `to` through `send`, with the line that says how to stop when
 * it's the first the number gets from the company, or always for a promotional one. Returns how
 * the send went.
 */
export async function textWithStopLine(
  admin: Db,
  companyId: string,
  to: string,
  body: string,
  send: (body: string) => Promise<SendResult>,
  options: { promotional?: boolean } = {},
): Promise<SendResult> {
  const telling = options.promotional === true || !(await wasTold(admin, companyId, to));
  const result = await send(telling ? addStopLine(body) : body);
  if (result.sent && telling) await noteTold(admin, companyId, to);
  return result;
}
