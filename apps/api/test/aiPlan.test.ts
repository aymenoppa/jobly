/**
 * Whose asks a ChatGPT plan pays for (services/ai.ts): only what the person who connected it asks
 * for themselves. Everyone else's asks, and what Jobly does by itself, stay on the company's
 * key; and when the plan can't take an ask it goes on to that key, with what stopped the plan kept
 * on the connection. OpenAI and Anthropic are a stubbed fetch built to their documentation
 * (fixtures/openaiSignIn.ts), and the database is kept in memory.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { decryptJson, encryptJson } from "../src/lib/crypto";
import { HttpError } from "../src/lib/http";
import { memoryDb, type MemoryDb, type Row } from "./fixtures/memoryDb";
import { LISTED, openai, planFunctions, refuses, says, type Call, type OpenAiWorld } from "./fixtures/openaiSignIn";

const world = vi.hoisted(() => ({ db: null as unknown as MemoryDb, viewer: "" }));
vi.mock("../src/lib/supabase", async () => {
  const { memoryClient } = await import("./fixtures/memoryDb");
  return { adminClient: () => memoryClient(() => world.db), userClient: () => memoryClient(() => world.db, () => ({ sub: world.viewer })), publishableKey: () => "key" };
});
const { aiAvailable, complete, readDocument } = await import("../src/services/ai");
const { adminClient } = await import("../src/lib/supabase");
const { forgetOpenAiSignIn } = await import("../src/integrations/chatgptPlan");
const { app } = await import("../src/app");

const env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  ENCRYPTION_KEY: btoa(String.fromCharCode(...new Uint8Array(32).map((_, i) => i * 7))),
} as Env;
const CO = "00000000-0000-4000-8000-0000000000c1";
// Pat connected their ChatGPT plan at Poplar Paving. Olive, in the office, hasn't.
const PAT = "00000000-0000-4000-8000-0000000000e1";
const OLIVE = "00000000-0000-4000-8000-0000000000e2";
let ai: OpenAiWorld;

const claudeSays = (text: string) => ({ id: "msg", type: "message", role: "assistant", model: "claude-opus-5-5", content: [{ type: "text", text }], stop_reason: "end_turn", stop_sequence: null, usage: { input_tokens: 4, output_tokens: 2 } });
/** The company's own keys, as Apps saves them. */
async function companyKeys(which: { claude?: boolean; openai?: boolean; choice?: "claude" | "chatgpt" } = { claude: true }) {
  world.db.tables.integrations = [];
  world.db.tables.integration_secrets = [];
  world.db.tables.companies = [{ id: CO, settings: which.choice ? { ai: { service: which.choice } } : {} }];
  if (which.claude) {
    world.db.tables.integrations.push({ company_id: CO, provider: "anthropic", status: "connected", settings: {} });
    world.db.tables.integration_secrets.push({ company_id: CO, provider: "anthropic", ciphertext: await encryptJson(env, { api_key: "sk-ant-company" }) });
  }
  if (which.openai) {
    world.db.tables.integrations.push({ company_id: CO, provider: "chatgpt", status: "connected", settings: { model: "gpt-6-luna", models: [{ slug: "gpt-6-luna", display_name: "gpt-6-luna" }] } });
    world.db.tables.integration_secrets.push({ company_id: CO, provider: "chatgpt", ciphertext: await encryptJson(env, { api_key: "sk-openai-company" }) });
  }
}
const plan = () => world.db.tables.chatgpt_plans![0]!;
const ask = (userId: string | null = PAT) => complete(env, { asker: { companyId: CO, userId }, system: "You edit short messages.", prompt: "we r coming tmrw", maxTokens: 1500 });
const read = (mediaType = "application/pdf", userId: string | null = PAT) =>
  readDocument(env, { asker: { companyId: CO, userId }, system: "Copy what is printed.", prompt: "Fill in the form.", file: { data: "AAAA", mediaType }, schema: { type: "object", additionalProperties: false, required: ["total"], properties: { total: { type: "number" } } } });
const refused = async (run: Promise<unknown>) => {
  const error = await run.then(() => null, (e: unknown) => e);
  return error instanceof HttpError ? [error.status, error.message] : error;
};
/** Who was asked, in order: Pat's plan, the company's OpenAI key, or the company's Claude key. */
const asked = () =>
  ai.calls.flatMap((c: Call) =>
    c.url.includes("anthropic.com") ? ["company claude"]
    : c.url.endsWith("/v1/responses") ? [c.bearer?.startsWith("plan-access") ? "plan" : c.bearer === "sk-openai-company" ? "company openai" : `? ${c.bearer}`]
    : []);

beforeEach(async () => {
  world.db = memoryDb({});
  planFunctions(world.db);
  await companyKeys();
  world.db.tables.chatgpt_plans = [{ user_id: PAT, company_id: CO, status: "connected", client_id: "oaiapp_pat", host_id: "urn:uuid:6f1b8f0e-3c59-4d0a-9d55-1f2a3b4c5d6e", account_sub: "user-pat", account_email: "pat@poplar.test", model: "gpt-6.1-sol", models: LISTED, unsupported: [], problem: null, problem_at: null, retry_at: null, notice_seen_at: null }];
  world.db.tables.chatgpt_plan_secrets = [{ user_id: PAT, company_id: CO, ciphertext: await encryptJson(env, { access_token: "plan-access-1", refresh_token: "plan-refresh-1", expires_at: Date.now() + 3_000_000, scope: "chatgpt.tokens.use.direct" }), refresh_claimed_until: null }];
  forgetOpenAiSignIn();
  ai = openai({ responses: () => says("We'll be there tomorrow."), other: () => claudeSays("From the company's key.") });
});
afterEach(() => vi.unstubAllGlobals());

describe("whose asks a ChatGPT plan pays for", () => {
  it("is what the person who connected it asks for themselves: on their plan's route, as a stream, with their model", async () => {
    expect(await ask()).toBe("We'll be there tomorrow.");
    expect(asked()).toEqual(["plan"]);
    expect(ai.calls[0]!.json).toEqual({ model: "gpt-6.1-sol", instructions: "You edit short messages.", input: [{ role: "user", content: "we r coming tmrw" }], store: false, stream: true, reasoning: { effort: "low" } });
  });

  it("is never another person's ask, and never what Jobly does by itself: those use the company's key", async () => {
    expect(await ask(OLIVE)).toBe("From the company's key.");
    expect(await ask(null)).toBe("From the company's key.");
    expect(await read("image/jpeg", null)).toBe("From the company's key.");
    expect(asked()).toEqual(["company claude", "company claude", "company claude"]);
    expect(ai.calls.every((c) => c.bearer === "sk-ant-company")).toBe(true);
  });

  it("comes before the company's keys whichever one the company chose, and what it can't take goes to the one chosen", async () => {
    await companyKeys({ claude: true, openai: true, choice: "chatgpt" });
    expect(await ask()).toBe("We'll be there tomorrow.");
    expect(asked()).toEqual(["plan"]);
    ai.responses = (call) => (call.bearer === "plan-access-1" ? refuses(429, "subscription_sharing_usage_limit_exceeded") : { id: "r", status: "completed", output: [{ type: "message", content: [{ type: "output_text", text: "From the company's OpenAI key." }] }] });
    ai.calls.length = 0;
    expect(await ask()).toBe("From the company's OpenAI key.");
    expect(asked()).toEqual(["plan", "company openai"]);
  });

  it("turns AI on for that person alone at a company with no key", async () => {
    await companyKeys({});
    expect(await aiAvailable(env, adminClient(env), { companyId: CO, userId: PAT })).toBe(true);
    expect(await aiAvailable(env, adminClient(env), { companyId: CO, userId: OLIVE })).toBe(false);
    expect(await aiAvailable(env, adminClient(env), { companyId: CO, userId: null })).toBe(false);
    expect(await ask()).toBe("We'll be there tomorrow.");
    expect(await refused(ask(OLIVE))).toEqual([501, "AI isn't turned on yet. An admin can add a Claude or OpenAI key on the Apps page."]);
  });
});

describe("when the plan can't take an ask", () => {
  it("at its usage limit, the company's key answers, the limit shows on the connection, and the plan is left alone for a while", async () => {
    ai.responses = () => refuses(429, "subscription_sharing_usage_limit_exceeded");
    expect(await ask()).toBe("From the company's key.");
    expect(asked()).toEqual(["plan", "company claude"]);
    expect(plan()).toMatchObject({ status: "connected", problem: "usage_limit" });
    // A pause, not a guess at when the limit resets: about a quarter of an hour.
    const pause = Date.parse(plan().retry_at) - Date.now();
    expect(pause).toBeGreaterThan(14 * 60_000);
    expect(pause).toBeLessThanOrEqual(15 * 60_000);

    ai.calls.length = 0;
    expect(await ask()).toBe("From the company's key.");
    expect(asked()).toEqual(["company claude"]);

    // Later, an ask tries the plan again; once it works, the limit is cleared.
    plan().retry_at = new Date(Date.now() - 1000).toISOString();
    ai.responses = () => says("Back on the plan.");
    ai.calls.length = 0;
    expect(await ask()).toBe("Back on the plan.");
    expect(asked()).toEqual(["plan"]);
    expect(plan()).toMatchObject({ problem: null, retry_at: null });
  });

  it("at a usage limit that arrives partway through the stream, the same", async () => {
    ai.responses = () => ({ stream: [{ type: "response.output_text.delta", delta: "We'll be" }, { type: "response.failed", response: { status: "failed", error: { code: "subscription_sharing_usage_limit_exceeded" } } }] });
    expect(await ask()).toBe("From the company's key.");
    expect(asked()).toEqual(["plan", "company claude"]);
    expect(plan().problem).toBe("usage_limit");
  });

  it("when OpenAI says the plan isn't eligible, the company's key answers and the plan isn't asked again for a day", async () => {
    ai.responses = () => refuses(403, "subscription_sharing_user_not_eligible");
    expect(await ask()).toBe("From the company's key.");
    expect(plan().problem).toBe("not_eligible");
    expect(Date.parse(plan().retry_at) - Date.now()).toBeGreaterThan(23 * 3_600_000);
    ai.calls.length = 0;
    await ask();
    expect(asked()).toEqual(["company claude"]);
  });

  it("when the plan route doesn't support reading a file, the company's key reads it, and that kind of file isn't sent to the plan again", async () => {
    ai.responses = () => refuses(400, "subscription_sharing_unsupported_capability", "input[0].content[0]");
    expect(await read("application/pdf")).toBe("From the company's key.");
    expect(asked()).toEqual(["plan", "company claude"]);
    // Not a problem with the connection: only this kind of ask.
    expect(plan()).toMatchObject({ problem: null, unsupported: ["pdf"] });
    ai.calls.length = 0;
    expect(await read("application/pdf")).toBe("From the company's key.");
    expect(asked()).toEqual(["company claude"]);
    // What the plan does take still goes to it.
    ai.responses = () => says("On the plan.");
    ai.calls.length = 0;
    expect(await ask()).toBe("On the plan.");
    expect(asked()).toEqual(["plan"]);
  });

  it("when the plan route doesn't take the answer's schema, tries once without strict mode, then leaves documents to the company's key", async () => {
    ai.responses = () => refuses(400, "subscription_sharing_unsupported_capability", "text.format");
    expect(await read("image/jpeg")).toBe("From the company's key.");
    expect(ai.calls.filter((c) => c.url.endsWith("/v1/responses")).map((c) => c.json!.text.format.strict)).toEqual([true, false]);
    expect(plan().unsupported).toEqual(["schema"]);
    ai.calls.length = 0;
    await read("image/jpeg");
    expect(asked()).toEqual(["company claude"]);
  });

  it("when the plan's model doesn't take reasoning effort, asks again without it and remembers", async () => {
    ai.responses = (call) => (call.json!.reasoning ? refuses(400, "subscription_sharing_unsupported_capability", "reasoning.effort") : says("Without effort."));
    expect(await ask()).toBe("Without effort.");
    expect(asked()).toEqual(["plan", "plan"]);
    expect(plan().unsupported).toEqual(["effort"]);
    ai.calls.length = 0;
    await ask();
    expect(ai.calls.map((c) => Boolean(c.json!.reasoning))).toEqual([false]);
  });

  it("when the sign-in has run out, the company's key answers and the connection says Sign in again", async () => {
    world.db.tables.chatgpt_plan_secrets![0]!.ciphertext = await encryptJson(env, { access_token: "plan-access-1", refresh_token: "plan-refresh-1", expires_at: Date.now() - 1000, scope: "chatgpt.tokens.use.direct" });
    ai.token = () => ({ status: 400, body: { error: "invalid_grant" } });
    expect(await ask()).toBe("From the company's key.");
    expect(asked()).toEqual(["company claude"]);
    expect(plan()).toMatchObject({ status: "disconnected", problem: "sign_in" });
    expect(world.db.tables.chatgpt_plan_secrets).toEqual([]);
  });

  it("when OpenAI turns the token down, refreshes it once before deciding anything about the sign-in", async () => {
    ai.responses = (call) => (call.bearer === "plan-access-1" ? refuses(401, "subscription_sharing_invalid_user") : says("With the new token."));
    ai.token = () => ({ access_token: "plan-access-2", refresh_token: "plan-refresh-2", expires_in: 3600, scope: "chatgpt.tokens.use.direct" });
    expect(await ask()).toBe("With the new token.");
    expect(ai.calls.filter((c) => c.url.endsWith("/v1/responses")).map((c) => c.bearer)).toEqual(["plan-access-1", "plan-access-2"]);
    expect(await decryptJson<Row>(env, world.db.tables.chatgpt_plan_secrets![0]!.ciphertext)).toMatchObject({ refresh_token: "plan-refresh-2" });
    expect(plan()).toMatchObject({ status: "connected", problem: null });
    // Turned down again after a good refresh: not the person's to fix by signing in, so nothing is marked.
    ai.responses = () => refuses(401, "subscription_sharing_invalid_user");
    ai.token = () => ({ access_token: "plan-access-3", refresh_token: "plan-refresh-3", expires_in: 3600, scope: "chatgpt.tokens.use.direct" });
    expect(await ask()).toBe("From the company's key.");
    expect(plan()).toMatchObject({ status: "connected", problem: null });
  });

  it("when the sign-in doesn't cover plan use anymore, the connection says Sign in again", async () => {
    ai.responses = () => refuses(403, "chatpass_v2_scope_not_authorized");
    expect(await ask()).toBe("From the company's key.");
    expect(plan()).toMatchObject({ status: "connected", problem: "sign_in", retry_at: null });
    ai.calls.length = 0;
    await ask();
    expect(asked()).toEqual(["company claude"]);
  });

  it("when OpenAI is down or the stream is cut, the company's key answers and nothing is held against the plan", async () => {
    for (const answer of [refuses(503, "subscription_sharing_usage_unavailable"), { status: 503, body: { detail: "Direct routing unavailable" } }, { stream: [{ type: "response.output_text.delta", delta: "We'll be th" }] }]) {
      ai.responses = () => answer;
      ai.calls.length = 0;
      expect(await ask()).toBe("From the company's key.");
      expect(asked()).toEqual(["plan", "company claude"]);
      expect(plan()).toMatchObject({ status: "connected", problem: null });
    }
  });

  it("when the plan's tokens can't be read at all, the company's key answers rather than the ask failing", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined);
    // Sealed with another key: the server's encryption key was changed.
    world.db.tables.chatgpt_plan_secrets![0]!.ciphertext = "v1.AAAAAAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    expect(await ask()).toBe("From the company's key.");
    expect(asked()).toEqual(["company claude"]);
    vi.restoreAllMocks();
  });

  it("when a proxy in the way answers 403 with its own page, that says nothing about the plan", async () => {
    ai.responses = () => ({ status: 403, body: "<html>Forbidden</html>" });
    expect(await ask()).toBe("From the company's key.");
    expect(plan()).toMatchObject({ status: "connected", problem: null });
  });

  it("when OpenAI turns an ask down as unsupported without saying what, nothing is held against files", async () => {
    ai.responses = () => refuses(400, "subscription_sharing_unsupported_capability");
    expect(await read("image/jpeg")).toBe("From the company's key.");
    expect(plan().unsupported).toEqual([]);
  });

  it("when the model picked is gone from the plan, moves to one OpenAI lists now", async () => {
    ai.responses = (call) => (call.json!.model === "gpt-6.1-sol" ? refuses(400, "subscription_sharing_unsupported_capability", "model") : says("On the newer model."));
    ai.models = { models: [{ slug: "gpt-7-nova", display_name: "GPT-7 Nova", visibility: "list" }] };
    expect(await ask()).toBe("On the newer model.");
    expect(ai.calls.filter((c) => c.url.endsWith("/v1/responses")).map((c) => c.json!.model)).toEqual(["gpt-6.1-sol", "gpt-7-nova"]);
    expect(plan()).toMatchObject({ model: "gpt-7-nova", models: [{ slug: "gpt-7-nova", display_name: "GPT-7 Nova" }] });
  });

  it("an answer that came but was declined or cut off is the answer: it isn't asked for again on the company's key", async () => {
    ai.responses = () => ({ stream: [{ type: "response.refusal.delta", delta: "I can't" }, { type: "response.completed", response: { status: "completed", output: [{ type: "message", content: [{ type: "refusal", refusal: "I can't help with that." }] }] } }] });
    expect(await refused(ask())).toEqual([422, "The AI declined that request. Try rephrasing it."]);
    ai.responses = () => ({ stream: [{ type: "response.incomplete", response: { status: "incomplete", incomplete_details: { reason: "max_output_tokens" } } }] });
    expect(await refused(ask())).toEqual([502, "The AI's answer was cut off before it finished. Try again, or ask for something shorter."]);
    expect(asked()).toEqual(["plan", "plan"]);
  });
});

describe("with no key of the company's to go on to", () => {
  beforeEach(() => companyKeys({}));

  it("says Usage limit reached and where to manage it, now and while the plan is paused", async () => {
    ai.responses = () => refuses(429, "subscription_sharing_usage_limit_exceeded");
    const limit = [429, "Usage limit reached. Review your plan or this app's limit in ChatGPT settings: https://chatgpt.com/settings/usage"];
    expect(await refused(ask())).toEqual(limit);
    expect(await refused(ask())).toEqual(limit);
    expect(asked()).toEqual(["plan"]);
  });

  it("says to sign in again, that the plan isn't eligible, that the plan can't do it here, or that ChatGPT couldn't be reached", async () => {
    ai.responses = () => refuses(403, "subscription_sharing_user_not_eligible");
    expect(await refused(ask())).toEqual([409, "Your ChatGPT plan can't be used here. ChatGPT Plus and Pro plans can be used; an OpenAI API key is the other way."]);
    plan().problem = null;
    ai.responses = () => refuses(400, "subscription_sharing_unsupported_capability", "input[0].content[0]");
    expect(await refused(read())).toEqual([422, "Your ChatGPT plan can't do that here. An admin can add a Claude or OpenAI key on the Apps page for it."]);
    ai.responses = () => refuses(503, "subscription_sharing_user_unavailable");
    expect(await refused(ask())).toEqual([503, "ChatGPT couldn't be reached. Try again in a minute."]);
    ai.responses = () => refuses(403, "chatpass_v2_invalid_authorization_context");
    const again = [409, "Your ChatGPT sign-in has ended. Sign in again under Settings → AI assistants."];
    expect(await refused(ask())).toEqual(again);
    // Still so after the tokens are gone (the refresh was refused): the page says the same.
    Object.assign(plan(), { status: "disconnected", problem: "sign_in" });
    expect(await refused(ask())).toEqual(again);
  });

  it("never says a token in any of it", async () => {
    const said: string[] = [];
    for (const answer of [refuses(429, "subscription_sharing_usage_limit_exceeded"), refuses(401, "subscription_sharing_invalid_user"), refuses(500, "server_error")]) {
      plan().problem = null;
      ai.responses = () => answer;
      ai.token = () => ({ status: 400, body: { error: "invalid_grant", error_description: "plan-refresh-1 is not valid" } });
      said.push(JSON.stringify(await refused(ask())));
    }
    expect(said.join(" ")).not.toMatch(/plan-access|plan-refresh/);
  });
});

describe("a receipt", () => {
  const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1]);
  const found = JSON.stringify({ kind: "receipt", vendor: "Valley Asphalt", date: null, invoice_number: null, subtotal: null, tax: null, total: 40, category: null, lines: [], job_reference: { job_number: null, po_number: null, address: null } });
  const MINE = "00000000-0000-4000-8000-0000000000d1";
  const HERS = "00000000-0000-4000-8000-0000000000d2";
  const request = (path: string, body?: unknown) => {
    world.viewer = PAT;
    return app.request(`/api${path}`, { method: "POST", headers: { Authorization: "Bearer token", "X-Company-Id": CO, "Content-Type": "application/json" }, body: JSON.stringify(body ?? {}) }, { ...env, SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test" } as Env);
  };

  beforeEach(() => {
    world.db.tables.memberships = [{ company_id: CO, user_id: PAT, active: true, role: "owner", role_id: null, subcontractor_id: null }];
    world.db.tables.companies![0]!.settings = { receipt_reading: true };
    world.db.tables.expense_drafts = [MINE, HERS].map((id) => ({ id, company_id: CO, job_id: null, user_id: id === MINE ? PAT : OLIVE, receipt_path: `${CO}/receipts/${id}.jpg`, status: "reading", read: null, error: null }));
    world.db.files = { [`${CO}/receipts/${MINE}.jpg`]: JPEG, [`${CO}/receipts/${HERS}.jpg`]: JPEG };
    ai.responses = () => says(found);
    ai.other = () => claudeSays(found);
  });

  it("someone picks in Add expense, or drops in themselves, is read on their own plan", async () => {
    expect((await request("/receipts/read", { file: Buffer.from(JPEG).toString("base64") })).status).toBe(200);
    expect((await request(`/receipts/drafts/${MINE}/read`)).status).toBe(200);
    expect(asked()).toEqual(["plan", "plan"]);
    expect(world.db.tables.expense_drafts![0]).toMatchObject({ status: "read" });
    // The picture went as an image, with the form's schema.
    expect(ai.calls[0]!.json!.input[0].content[0].type).toBe("input_image");
    expect(ai.calls[0]!.json!.text.format.type).toBe("json_schema");
  });

  it("someone else left waiting is read with the company's key, not on the plan of whoever's page reads it", async () => {
    expect((await request(`/receipts/drafts/${HERS}/read`)).status).toBe(200);
    expect(asked()).toEqual(["company claude"]);
    expect(world.db.tables.expense_drafts![1]).toMatchObject({ status: "read" });
  });
});
