/**
 * A website form's bot check (routes/websiteForms.ts; supabase/migrations/20261117000100_form_bot_checks.sql),
 * on top of the hidden field and the limits every form has. Each form chooses one:
 *
 *   script     Jobly's own. One script line on the business's page (GET /f/<key>/check.js, made
 *              here) asks this server for a token as the page loads (POST /f/<key>/check) and puts
 *              it in the form's hidden _check field. A message passes with a token this server
 *              signed for this form, from a page that has been open at least 3 seconds (nobody
 *              fills in a form faster), that hasn't already sent 3 messages. It stops what doesn't
 *              run a real browser, which is most bots; one that does run a browser, or is written
 *              for Jobly, gets through.
 *   turnstile  Cloudflare's. Its widget on the business's page sends an answer with the message,
 *              and Cloudflare says whether it's good, with the business's own keys (the secret key
 *              is kept encrypted: website_form_turnstile).
 *
 * A check only watches until an owner or admin tells the form to refuse messages without it (the
 * route notes what passed and what didn't, so they can see whether every page has the line). And
 * when the check itself can't be made (Cloudflare is down, or the keys stopped working), the message
 * comes through unchecked: a lead matters more than a bot.
 *
 * Real people mustn't be the ones it stops. So a page's token is good for three messages (a second
 * message, a double-click, a try again after something else went wrong), and a page that asks for a
 * new token hands over its old one and keeps its age: coming Back to the form, the half-hourly
 * refresh and a tab waking up never make a page look too new to have been filled in.
 */
import { CHECK_FIELD, isTurnstileSiteKey, TURNSTILE_FIELD, type BotCheck } from "@jobly/core/websiteForms";
import type { Env } from "../env";
import { decryptJson, encryptJson, randomId, signToken, verifyToken } from "../lib/crypto";
import { dbError, HttpError } from "../lib/http";
import { allow } from "../lib/limit";
import { reportError } from "../lib/monitoring";
import type { Db } from "../lib/supabase";

/** How long a page's token is good for: a tab left open all day still sends. The script gets a new one every half hour. */
export const CHECK_VALID_SECONDS = 12 * 60 * 60;
/** Nobody reads a form, fills it in and sends it this fast after the page loads. */
export const CHECK_MIN_AGE_MS = 3000;
/** How many messages one token sends: a second message from the same page, a double-click, a try again. */
export const CHECK_USES = 3;
/** How long the script keeps a token before asking for a new one. */
const CHECK_REFRESH_MS = 30 * 60 * 1000;
/** How long the script waits after an ask that failed, so a page can't use up its visitor's asks. */
const CHECK_RETRY_MS = 60 * 1000;
/** A token is a few hundred characters; nothing longer is read. */
const TOKEN_MAX = 800;

const SITEVERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";
const TURNSTILE_TIMEOUT_MS = 8000;

interface CheckToken {
  k: "form-check";
  /** The form's address: a token is for one form, and stops working when the form gets a new address. */
  f: string;
  /** Its own id: each token sends CHECK_USES messages. */
  n: string;
  /** When its page first got a token, in milliseconds: a page's later tokens keep it. */
  b: number;
  exp: number;
}

const isCheckToken = (token: CheckToken | null, formKey: string): token is CheckToken =>
  Boolean(token && token.k === "form-check" && token.f === formKey && typeof token.n === "string" && typeof token.b === "number" && Number.isFinite(token.b));

/**
 * A token for a page showing this form, signed by this server. `was`: the token the page had, when
 * it had one. If it's this server's and for this form, even one that has run out, the new token is
 * as old as that one, so a page that only refreshed its token isn't taken for one that just opened.
 */
export async function newCheckToken(env: Env, formKey: string, was?: string | null, now = Date.now()): Promise<string> {
  let born = now;
  if (was && was.length <= TOKEN_MAX) {
    const before = await verifyToken<CheckToken>(env, was, { expired: true }).catch(() => null);
    if (isCheckToken(before, formKey) && before.b <= now) born = before.b;
  }
  const token: CheckToken = { k: "form-check", f: formKey, n: randomId(9), b: born, exp: Math.floor(now / 1000) + CHECK_VALID_SECONDS };
  return signToken(env, { ...token });
}

/**
 * What became of a message's check.
 *   passed     it carried good proof
 *   unchecked  the check couldn't be made (no keys, or Cloudflare didn't answer): it comes through
 *   otherwise  why it failed, for what the visitor is told
 */
export type CheckResult = "passed" | "unchecked" | "missing" | "invalid" | "too_fast" | "used" | "turnstile";

const sentText = (sent: ReadonlyArray<[string, unknown]>, field: string): string => {
  const value = sent.find(([name]) => name.trim().toLowerCase() === field)?.[1];
  return typeof value === "string" ? value.trim() : "";
};

/** Jobly's own check: the token in _check. A good one has one of its uses taken here. */
async function checkToken(env: Env, formKey: string, sent: ReadonlyArray<[string, unknown]>, now: number): Promise<CheckResult> {
  const raw = sentText(sent, CHECK_FIELD);
  if (!raw) return "missing";
  if (raw.length > TOKEN_MAX) return "invalid";
  const token = await verifyToken<CheckToken>(env, raw).catch(() => null);
  if (!isCheckToken(token, formKey)) return "invalid";
  if (now - token.b < CHECK_MIN_AGE_MS) return "too_fast";
  return (await allow(env, `form-check-used:${token.n}`, CHECK_USES, CHECK_VALID_SECONDS)) ? "passed" : "used";
}

interface Siteverify {
  success?: boolean;
  "error-codes"?: string[];
}

/** Cloudflare's answers that mean the keys or Cloudflare itself are the problem, not whoever sent the message. */
const NOT_THE_VISITOR = ["missing-input-secret", "invalid-input-secret", "internal-error"];

/** Ask Cloudflare about an answer. Null when it can't be reached or doesn't say. */
async function siteverify(secret: string, response: string, ip?: string): Promise<Siteverify | null> {
  try {
    const body = new URLSearchParams({ secret, response });
    if (ip && ip !== "unknown") body.set("remoteip", ip);
    const res = await fetch(SITEVERIFY, { method: "POST", body, signal: AbortSignal.timeout(TURNSTILE_TIMEOUT_MS) });
    const json = (await res.json().catch(() => null)) as Siteverify | null;
    return json && typeof json === "object" && typeof json.success === "boolean" ? json : null;
  } catch {
    return null;
  }
}

/**
 * The business's Turnstile keys, or null when it has none. `secret` is null when keys are saved but
 * can't be read with this server's key any more (ENCRYPTION_KEY changed, or the database was restored
 * into a new Jobly): nothing can be checked until they're entered again.
 */
export async function loadTurnstile(env: Env, admin: Db, companyId: string): Promise<{ siteKey: string; secret: string | null } | null> {
  const { data, error } = await admin.from("website_form_turnstile").select("site_key, ciphertext").eq("company_id", companyId).maybeSingle();
  if (error) throw dbError(error);
  if (!data) return null;
  const kept = await decryptJson<{ secret?: string }>(env, data.ciphertext).catch(() => null);
  return { siteKey: data.site_key, secret: kept?.secret || null };
}

/** Turnstile: the widget's answer, asked of Cloudflare with the business's secret key. */
async function checkTurnstile(env: Env, admin: Db, companyId: string, sent: ReadonlyArray<[string, unknown]>, ip: string): Promise<CheckResult> {
  const keys = await loadTurnstile(env, admin, companyId).catch((error) => {
    reportError(error, { check: "turnstile-keys" });
    return null;
  });
  if (!keys) return "unchecked";
  if (!keys.secret) {
    console.warn("A website form is set to Turnstile, but its business's keys can't be read any more (has ENCRYPTION_KEY changed?), so the message came through unchecked. Enter the keys again in Apps.");
    reportError(new Error("Turnstile keys can't be decrypted"), { check: "turnstile-keys", company: companyId });
    return "unchecked";
  }
  const answer = sentText(sent, TURNSTILE_FIELD);
  if (!answer) return "missing";
  if (answer.length > 2048) return "turnstile";
  const said = await siteverify(keys.secret, answer, ip);
  if (said?.success) return "passed";
  const codes = said?.["error-codes"] ?? [];
  if (!said || codes.some((code) => NOT_THE_VISITOR.includes(code))) {
    console.warn(`A website form's Turnstile check couldn't be made (${said ? codes.join(", ") : "Cloudflare didn't answer"}), so the message came through unchecked.`);
    if (said) reportError(new Error(`Turnstile check couldn't be made: ${codes.join(", ")}`), { check: "turnstile" });
    return "unchecked";
  }
  return "turnstile";
}

/** Check a message against its form's check. Off, or a check that couldn't be made, is "unchecked". */
export async function checkMessage(
  env: Env,
  admin: Db,
  form: { key: string; bot_check: BotCheck; company: { id: string } },
  sent: ReadonlyArray<[string, unknown]>,
  ip: string,
  now = Date.now(),
): Promise<CheckResult> {
  if (form.bot_check === "script") return checkToken(env, form.key, sent, now);
  if (form.bot_check === "turnstile") return checkTurnstile(env, admin, form.company.id, sent, ip);
  return "unchecked";
}

/**
 * What someone is told when a form that refuses turns their message away, and the status it goes
 * with. Always with another way to reach the business: a real person can end up here.
 */
export function checkRefusal(result: Exclude<CheckResult, "passed" | "unchecked">, check: BotCheck, kind: "contact" | "careers"): { status: 403 | 429; message: string } {
  if (check === "turnstile") {
    return { status: 403, message: "We couldn't confirm you're a person. Go back, reload the page, finish the check above the button and send it again. If no check shows up there, call us instead." };
  }
  if (result === "too_fast") return { status: 429, message: "That was sent too fast for us to check it. Wait a few seconds and send it again, or call us." };
  if (result === "used") {
    return { status: 403, message: `This page has sent as many ${kind === "careers" ? "applications" : "messages"} as it can. To send another, go back, reload the page and send it again, or call us.` };
  }
  return { status: 403, message: "We couldn't check that a person sent this. Go back, reload the page and send it again, with JavaScript turned on in your browser. Or call us." };
}

// ---------------------------------------------------------------------------------------------
// The business's Turnstile keys
// ---------------------------------------------------------------------------------------------

export const SECRET_WRONG =
  "Cloudflare doesn't know that secret key. In Cloudflare, open Turnstile, pick your widget and copy its Secret key again (not the Site key), then save.";
export const CLOUDFLARE_UNREACHABLE = "Couldn't reach Cloudflare to test the secret key, so nothing was saved. Try again in a minute.";
export const CLOUDFLARE_UNSURE = "Cloudflare couldn't test the secret key just now, so nothing was saved. Try again in a minute.";
export const SITE_KEY_WRONG = "That doesn't look like a Turnstile site key. In Cloudflare, open Turnstile, pick your widget and copy its Site key: it starts with 0x.";

/**
 * Save a business's Turnstile keys, once Cloudflare has taken the secret key: it's asked about a
 * made-up answer, which a good secret gets "that answer is wrong" for (or, with Cloudflare's own
 * test keys, a pass) and a bad one "that secret is wrong". Anything else proves nothing, so nothing
 * is saved. The site key can't be asked about; it's only checked for its shape.
 */
export async function saveTurnstile(env: Env, admin: Db, companyId: string, siteKey: string, secretKey: string): Promise<void> {
  if (!isTurnstileSiteKey(siteKey)) throw new HttpError(400, SITE_KEY_WRONG);
  const said = await siteverify(secretKey, "test");
  if (!said) throw new HttpError(502, CLOUDFLARE_UNREACHABLE);
  const codes = said["error-codes"] ?? [];
  if (codes.includes("invalid-input-secret") || codes.includes("missing-input-secret")) throw new HttpError(400, SECRET_WRONG);
  if (!said.success && !codes.includes("invalid-input-response")) throw new HttpError(502, CLOUDFLARE_UNSURE);
  const { error } = await admin
    .from("website_form_turnstile")
    .upsert({ company_id: companyId, site_key: siteKey, ciphertext: await encryptJson(env, { secret: secretKey }), updated_at: new Date().toISOString() });
  if (error) throw dbError(error);
}

// ---------------------------------------------------------------------------------------------
// The script on the business's page
// ---------------------------------------------------------------------------------------------

/**
 * check.js for one form: gets a token from `checkUrl` as the page loads and keeps it in a hidden
 * _check field in every form that sends to this address, including forms drawn later and forms sent
 * with fetch() (the field is put in as a submit starts, before anything reads the form). It asks for
 * a new token, handing over the one it has so the page keeps its age, when the page comes back from
 * the browser's Back button, when its token is half an hour old, and a moment after the form is
 * sent (for a page that stays open and sends again). The token is also kept for the tab
 * (sessionStorage, where the browser allows it), so a page the browser loads afresh on Back, or one
 * the visitor reloads, hands over the one it had too. After an ask that failed it waits a minute.
 * Plain old JavaScript, so it runs wherever the website does; when anything fails it does nothing.
 */
export function checkScript(checkUrl: string, formKey: string): string {
  return `/* Jobly: checks that a person is sending this website's form. */
(function () {
  "use strict";
  var ASK = ${JSON.stringify(checkUrl)}, PATH = ${JSON.stringify(`/f/${formKey}`)}, FIELD = ${JSON.stringify(CHECK_FIELD)}, FRESH = ${CHECK_REFRESH_MS}, RETRY = ${CHECK_RETRY_MS};
  var KEPT = "jobly-check:" + PATH;
  var token = "", had = "", at = 0, failedAt = 0, asking = false;
  function now() { return new Date().getTime(); }
  function kept(value) {
    try {
      if (value === undefined) return String(window.sessionStorage.getItem(KEPT) || "");
      window.sessionStorage.setItem(KEPT, value);
    } catch (error) {}
    return "";
  }
  function ours(form) { return Boolean(form && form.getAttribute) && String(form.getAttribute("action") || "").indexOf(PATH) !== -1; }
  function put() {
    if (!token) return;
    var forms = document.getElementsByTagName("form");
    for (var i = 0; i < forms.length; i++) {
      var form = forms[i];
      if (!ours(form)) continue;
      var field = form.querySelector('input[name="' + FIELD + '"]');
      if (!field) {
        field = document.createElement("input");
        field.type = "hidden";
        field.name = FIELD;
        form.appendChild(field);
      }
      field.value = token;
    }
  }
  function failed() { asking = false; failedAt = now(); }
  function ask() {
    if (asking || !window.fetch || now() - failedAt < RETRY) return;
    asking = true;
    var options = { method: "POST" }, was = token || had;
    if (was) {
      options.headers = { "Content-Type": "application/x-www-form-urlencoded" };
      options.body = "was=" + encodeURIComponent(was);
    }
    fetch(ASK, options)
      .then(function (res) { return res.ok ? res.json() : null; })
      .then(function (data) {
        if (!data || !data.token) return failed();
        asking = false;
        token = data.token;
        at = now();
        kept(token);
        put();
      })
      .catch(failed);
  }
  function fresh() {
    put();
    if (now() - at > FRESH) ask();
  }
  function sending(event) {
    put();
    if (ours(event && event.target)) setTimeout(ask, 1500);
  }
  try {
    had = kept();
    ask();
    document.addEventListener("DOMContentLoaded", put);
    document.addEventListener("focusin", fresh);
    document.addEventListener("submit", sending, true);
    window.addEventListener("pageshow", function (event) {
      if (!event.persisted) return;
      failedAt = 0;
      ask();
    });
    setInterval(fresh, 60000);
  } catch (error) {}
})();
`;
}
