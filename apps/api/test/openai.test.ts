/**
 * OpenAI's Responses API as Jobly asks it (integrations/openai.ts): what's sent on each route,
 * and reading the event stream a ChatGPT plan answers with. OpenAI is a stubbed fetch, built to its
 * published documentation: nothing here has run against the real service.
 */
import { afterEach, describe, expect, it, vi } from "vitest";
import { askWithPlan, listPlanModels, OpenAiProblem, pickModel, readStream, responsesBody, type OpenAiAsk } from "../src/integrations/openai";
import type { Env } from "../src/env";

const ask: OpenAiAsk = { model: "gpt-6.1-sol", system: "You edit short messages.", prompt: "we r coming tmrw", effort: "low", maxTokens: 1500, timeoutMs: 5000 };

/** A Responses event stream, as server-sent events, delivered in pieces of `split` bytes (0: all at once). */
const stream = (events: Array<Record<string, unknown>>, split = 0) => {
  const text = events.map((e) => `event: ${e.type}\ndata: ${JSON.stringify(e)}\n\n`).join("");
  const bytes = new TextEncoder().encode(text);
  // In pieces that don't line up with the events, as a network delivers them.
  const size = split || bytes.length || 1;
  return new ReadableStream<Uint8Array>({
    start(controller) {
      for (let i = 0; i < bytes.length; i += size) controller.enqueue(bytes.slice(i, i + size));
      controller.close();
    },
  });
};
const delta = (text: string) => ({ type: "response.output_text.delta", delta: text });
const completed = (text?: string) => ({ type: "response.completed", response: { status: "completed", output: text === undefined ? [] : [{ type: "message", content: [{ type: "output_text", text }] }] } });
const problem = async (run: Promise<unknown>) => {
  const error = await run.then(() => null, (e: unknown) => e);
  return error instanceof OpenAiProblem ? [error.kind, error.code] : error;
};

afterEach(() => vi.unstubAllGlobals());

describe("what's asked of the Responses API", () => {
  it("on a ChatGPT plan is a stream with nothing kept, the system text as instructions, and none of the fields that route refuses", () => {
    const body = responsesBody({ ...ask, schema: { type: "object" } }, "plan");
    expect(body).toEqual({
      model: "gpt-6.1-sol",
      instructions: "You edit short messages.",
      input: [{ role: "user", content: "we r coming tmrw" }],
      store: false,
      stream: true,
      reasoning: { effort: "low" },
      text: { format: { type: "json_schema", name: "answer", schema: { type: "object" }, strict: true } },
    });
    const refused = ["background", "conversation", "max_output_tokens", "max_tool_calls", "metadata", "moderation", "multi_agent", "prompt", "prompt_cache_retention", "safety_identifier", "temperature", "top_logprobs", "top_p", "truncation", "user", "previous_response_id"];
    expect(Object.keys(body).filter((key) => refused.includes(key))).toEqual([]);
    // No system-role message: the plan route rejects those.
    expect(JSON.stringify(body.input)).not.toContain('"system"');
  });

  it("with a key isn't a stream, and caps the answer with room to think", () => {
    const body = responsesBody(ask, "key");
    expect(body).toMatchObject({ store: false, max_output_tokens: 3500 });
    expect(body.stream).toBeUndefined();
    expect(responsesBody({ ...ask, effort: null }, "key")).toMatchObject({ max_output_tokens: 1500 });
    expect(responsesBody({ ...ask, effort: null }, "key").reasoning).toBeUndefined();
  });
});

describe("reading a plan's answer as it streams", () => {
  it("is the text once response.completed arrives, however the stream is cut into pieces", async () => {
    const events = [{ type: "response.created", response: { status: "in_progress" } }, delta("We'll be there "), delta("tomorrow."), completed("We'll be there tomorrow.")];
    expect(await readStream(stream(events))).toBe("We'll be there tomorrow.");
    expect(await readStream(stream(events, 7))).toBe("We'll be there tomorrow.");
    // A finished response that doesn't repeat the text: what streamed is the answer.
    expect(await readStream(stream([delta(" We'll be there. "), completed()]))).toBe("We'll be there.");
  });

  it("is not an answer when the stream stops before response.completed", async () => {
    expect(await problem(readStream(stream([delta("We'll be there tom")])))).toEqual(["interrupted", null]);
    expect(await problem(readStream(stream([])))).toEqual(["interrupted", null]);
  });

  it("is the usage limit when response.failed says so partway through", async () => {
    const failed = { type: "response.failed", response: { status: "failed", error: { code: "subscription_sharing_usage_limit_exceeded", message: "Usage limit reached" } } };
    expect(await problem(readStream(stream([delta("We'll be"), failed])))).toEqual(["usage_limit", "subscription_sharing_usage_limit_exceeded"]);
    const unavailable = { type: "response.failed", response: { status: "failed", error: { code: "subscription_sharing_usage_unavailable" } } };
    expect(await problem(readStream(stream([unavailable])))).toEqual(["unavailable", "subscription_sharing_usage_unavailable"]);
    expect(await problem(readStream(stream([{ type: "response.failed", response: { status: "failed" } }])))).toEqual(["error", null]);
  });

  it("is cut off, declined or empty as with any answer", async () => {
    expect(await problem(readStream(stream([delta("We'll"), { type: "response.incomplete", response: { status: "incomplete", incomplete_details: { reason: "max_output_tokens" } } }])))).toEqual(["cut_off", null]);
    expect(await problem(readStream(stream([{ type: "response.refusal.delta", delta: "I can't" }, completed()])))).toEqual(["declined", null]);
    expect(await problem(readStream(stream([completed()])))).toEqual(["empty", null]);
  });
});

describe("a plan's request that OpenAI turns down before any stream opens", () => {
  const refuse = (status: number, body: unknown) => vi.stubGlobal("fetch", async () => Response.json(body, { status }));
  const asked = () => problem(askWithPlan("plan-access-token", ask));

  it("is told apart by OpenAI's code", async () => {
    const cases: Array<[number, string, string]> = [
      [429, "subscription_sharing_usage_limit_exceeded", "usage_limit"],
      [403, "subscription_sharing_user_not_eligible", "not_eligible"],
      [503, "subscription_sharing_usage_unavailable", "unavailable"],
      [503, "subscription_sharing_user_unavailable", "unavailable"],
      [400, "subscription_sharing_unsupported_capability", "unsupported"],
      [403, "subscription_sharing_route_not_supported", "error"],
      [401, "subscription_sharing_invalid_user", "key"],
      [403, "chatpass_v2_scope_not_authorized", "not_allowed"],
      [403, "chatpass_v2_invalid_authorization_context", "not_allowed"],
    ];
    for (const [status, code, kind] of cases) {
      refuse(status, { error: { code, param: "input" } });
      expect(await asked()).toEqual([kind, code]);
    }
  });

  it("goes by the status when the body is only a detail, which isn't a code", async () => {
    refuse(401, { detail: "Signed identity not accepted" });
    expect(await asked()).toEqual(["key", null]);
    refuse(403, { detail: "Not available in your region" });
    expect(await asked()).toEqual(["not_eligible", null]);
    refuse(503, { detail: "Direct routing unavailable" });
    expect(await asked()).toEqual(["unavailable", null]);
  });

  it("never carries the token in what went wrong", async () => {
    refuse(401, { error: { code: "subscription_sharing_invalid_user", message: "bad token plan-access-token" } });
    const error = await askWithPlan("plan-access-token", ask).catch((e: unknown) => e);
    expect(`${String(error)} ${JSON.stringify(error)}`).not.toContain("plan-access-token");
  });
});

describe("a plan's models", () => {
  it("are the ones OpenAI marks for listing, in its order, by the name it shows", async () => {
    const calls: Array<[string, string | null]> = [];
    vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push([String(input), new Headers(init?.headers).get("authorization")]);
      return Response.json({ models: [{ slug: "gpt-6-astra", display_name: "GPT-6 Astra", visibility: "list" }, { slug: "gpt-6-internal", display_name: "Internal", visibility: "hide" }, { slug: "gpt-6.1-sol", display_name: "GPT-6.1 Sol", visibility: "list" }, { slug: "gpt-6-luna", visibility: "list" }] });
    });
    const models = await listPlanModels("plan-access-token");
    expect(models).toEqual([{ slug: "gpt-6-astra", display_name: "GPT-6 Astra" }, { slug: "gpt-6.1-sol", display_name: "GPT-6.1 Sol" }, { slug: "gpt-6-luna", display_name: "gpt-6-luna" }]);
    expect(calls).toEqual([["https://api.openai.com/v1/models", "Bearer plan-access-token"]]);
    // The one ticked to begin with is a general-purpose model when the plan has one, and the one picked before while it's still listed.
    expect(pickModel({} as Env, models)).toBe("gpt-6.1-sol");
    expect(pickModel({} as Env, models, "gpt-6-luna")).toBe("gpt-6-luna");
    expect(pickModel({} as Env, models, "gpt-5-gone")).toBe("gpt-6.1-sol");
    expect(pickModel({} as Env, [{ slug: "gpt-8", display_name: "GPT-8" }])).toBe("gpt-8");
    expect(pickModel({ OPENAI_MODEL: "gpt-6-luna" } as Env, models, "gpt-6-astra")).toBe("gpt-6-luna");
    expect(pickModel({} as Env, [])).toBeNull();
  });
});
