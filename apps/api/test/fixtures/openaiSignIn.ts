/**
 * OpenAI's sign-in service and API as a stubbed fetch, built to its published documentation
 * (developers.openai.com/siwc): its discovery document and signing keys, the token endpoint, signing
 * out, and a ChatGPT plan's models and answers. Each test says what the token endpoint and the API
 * answer; every request made comes back in `calls`. Nothing here has run against the real service.
 */
import { vi } from "vitest";
import type { MemoryDb, Row } from "./memoryDb";

export const ISSUER = "https://auth.openai.com";
export const SCOPE = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
export const PLAN_MODELS = { models: [{ slug: "gpt-6-astra", display_name: "GPT-6 Astra", visibility: "list" }, { slug: "gpt-6.1-sol", display_name: "GPT-6.1 Sol", visibility: "list" }, { slug: "gpt-6-hidden", display_name: "Hidden", visibility: "hide" }] };
export const LISTED = [{ slug: "gpt-6-astra", display_name: "GPT-6 Astra" }, { slug: "gpt-6.1-sol", display_name: "GPT-6.1 Sol" }];

const b64url = (bytes: Uint8Array | string) => Buffer.from(bytes).toString("base64url");

const signing = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const publicJwk = { ...(await crypto.subtle.exportKey("jwk", signing.publicKey)), kid: "openai-key-1", use: "sig", alg: "RS256" };
// A key that isn't OpenAI's, for a token someone else signed.
const forged = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);

/** An ID token as OpenAI issues one, signed with its key (or `forge`: with someone else's). */
export async function idToken(claims: Row, forge = false): Promise<string> {
  const head = b64url(JSON.stringify({ alg: "RS256", kid: "openai-key-1", typ: "JWT" }));
  const now = Math.floor(Date.now() / 1000);
  const body = b64url(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 3600, ...claims }));
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", (forge ? forged : signing).privateKey, new TextEncoder().encode(`${head}.${body}`));
  return `${head}.${body}.${b64url(new Uint8Array(signature))}`;
}

export interface Call {
  url: string;
  method: string;
  bearer: string | null;
  form: Record<string, string>;
  json: Row | null;
}
type Answer = { status?: number; body?: unknown; stream?: Row[] } | Row;
export interface OpenAiWorld {
  calls: Call[];
  /** The token endpoint's answer to a form (a code exchange or a refresh). */
  token?: (form: Record<string, string>, n: number) => Answer | Promise<Answer>;
  /** GET /v1/models, for a plan's token. */
  models?: Answer | ((call: Call) => Answer);
  /** POST /v1/responses: a list of stream events, or a refusal. */
  responses?: (call: Call, n: number) => Answer;
  /** Signing out: the status it answers with (200 unless set). */
  revoke?: number;
  /** Anything that isn't OpenAI's (Anthropic's API, for a company's Claude key). */
  other?: (call: Call) => Answer;
}

const answerOf = (a: Answer): Response => {
  if (a && "stream" in a && Array.isArray(a.stream)) {
    return new Response(a.stream.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join(""), { status: 200, headers: { "Content-Type": "text/event-stream" } });
  }
  if (a && ("status" in a || "body" in a) && (typeof a.status === "number" || a.body !== undefined)) return Response.json(a.body ?? {}, { status: (a.status as number) ?? 200 });
  return Response.json(a);
};

/** Stand in for OpenAI. Returns the world, whose answers a test can change as it goes. */
export function openai(world: Omit<OpenAiWorld, "calls"> = {}): OpenAiWorld {
  const w: OpenAiWorld = { calls: [], ...world };
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input);
    const body = init?.body;
    const call: Call = {
      url,
      method: init?.method ?? "GET",
      bearer: new Headers(init?.headers).get("authorization")?.replace(/^Bearer /, "") ?? new Headers(init?.headers).get("x-api-key"),
      form: body instanceof URLSearchParams ? Object.fromEntries(body) : {},
      json: typeof body === "string" ? (JSON.parse(body) as Row) : null,
    };
    w.calls.push(call);
    const count = () => w.calls.filter((c) => c.url === url).length;
    if (url === `${ISSUER}/.well-known/openid-configuration`) {
      return Response.json({ issuer: ISSUER, authorization_endpoint: `${ISSUER}/api/accounts/authorize`, token_endpoint: `${ISSUER}/api/accounts/oauth/token`, jwks_uri: `${ISSUER}/.well-known/jwks.json`, revocation_endpoint: `${ISSUER}/api/accounts/oauth/revoke` });
    }
    if (url === `${ISSUER}/.well-known/jwks.json`) return Response.json({ keys: [publicJwk] });
    if (url === `${ISSUER}/api/accounts/oauth/token`) return answerOf(w.token ? await w.token(call.form, count()) : { status: 500 });
    if (url === `${ISSUER}/api/accounts/oauth/revoke`) return new Response("", { status: w.revoke ?? 200 });
    if (url === "https://api.openai.com/v1/models") return answerOf(typeof w.models === "function" ? w.models(call) : (w.models ?? PLAN_MODELS));
    if (url === "https://api.openai.com/v1/responses") return answerOf(w.responses ? w.responses(call, count()) : { status: 500 });
    if (w.other && !url.includes("openai.com")) return answerOf(w.other(call));
    return Response.json({ error: { message: `unexpected request to ${url}` } }, { status: 500 });
  });
  return w;
}

/** A plan's whole answer as its stream of events. */
export const says = (text: string): Answer => ({ stream: [{ type: "response.created", response: { status: "in_progress" } }, { type: "response.output_text.delta", delta: text }, { type: "response.completed", response: { status: "completed", output: [{ type: "message", content: [{ type: "output_text", text }] }] } }] });
export const refuses = (status: number, code: string, param?: string): Answer => ({ status, body: { error: { code, message: code, ...(param ? { param } : {}) } } });

/** The database functions the plan's sign-in uses, acted out as they behave. */
export function planFunctions(db: MemoryDb) {
  db.keys.chatgpt_plans = ["user_id", "company_id"];
  db.keys.chatgpt_plan_secrets = ["user_id", "company_id"];
  db.tables.chatgpt_plans ??= [];
  db.tables.chatgpt_plan_secrets ??= [];
  db.tables.chatgpt_sign_ins ??= [];
  db.rpc.chatgpt_host_id = () => "urn:uuid:6f1b8f0e-3c59-4d0a-9d55-1f2a3b4c5d6e";
  // One refresher at a time: the tokens go to whoever asks first, and to nobody else for 30 seconds.
  db.rpc.claim_chatgpt_plan_refresh = (args, world) => {
    const row = world.tables.chatgpt_plan_secrets!.find((r) => r.user_id === args.p_user && r.company_id === args.p_company);
    if (!row || (row.refresh_claimed_until && row.refresh_claimed_until > new Date().toISOString())) return null;
    row.refresh_claimed_until = new Date(Date.now() + 30_000).toISOString();
    return row.ciphertext;
  };
  db.rpc.chatgpt_plan_leftovers = (_args, world) =>
    world.tables.chatgpt_plan_secrets!.flatMap((s) => {
      const plan = world.tables.chatgpt_plans!.find((p) => p.user_id === s.user_id && p.company_id === s.company_id);
      return plan?.status === "connected" ? [] : [{ user_id: s.user_id, company_id: s.company_id, ciphertext: s.ciphertext, client_id: plan?.client_id ?? null }];
    });
}
