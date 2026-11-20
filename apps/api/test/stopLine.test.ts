/**
 * Telling people how to stop texts (services/stopLine.ts): the first text Jobly writes to a
 * number ends with "Reply STOP to opt out.", the ones after it don't, and a promotional text always
 * does. Checked on the helper itself and through the automation engine, where reminders, visit
 * notices and a campaign's own text go out. PostgREST is a stand-in answering over fetch, and
 * sending is mocked.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import type { Db } from "../src/lib/supabase";

vi.mock("../src/lib/notify", async (original) => ({
  ...(await original<typeof import("../src/lib/notify")>()),
  emailReady: vi.fn(async () => true),
  sendEmail: vi.fn(async () => ({ sent: true, id: "email-1" })),
  sendSms: vi.fn(async () => ({ sent: true, id: "sms-1" })),
}));

const notify = await import("../src/lib/notify");
const { executeRun } = await import("../src/services/automations");
const { textWithStopLine } = await import("../src/services/stopLine");
const { adminClient } = await import("../src/lib/supabase");
const sendSms = vi.mocked(notify.sendSms);

const env: Env = {
  SUPABASE_URL: "https://example.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_test",
  SUPABASE_SECRET_KEY: "sb_secret_test",
  ENCRYPTION_KEY: btoa(String.fromCharCode(...new Uint8Array(32).map((_, i) => i * 7))),
  APP_URL: "https://ops.example.com",
  TWILIO_ACCOUNT_SID: "AC123",
  TWILIO_AUTH_TOKEN: "twilio-token",
  TWILIO_FROM_NUMBER: "+15125550000",
};
const CO = "00000000-0000-4000-8000-0000000000c1";
const ANA_ID = "00000000-0000-4000-8000-0000000000a1";
const STOP = "Reply STOP to opt out.";

type Row = Record<string, any>;
interface Call {
  method: string;
  path: string;
  params: URLSearchParams;
  body: any;
}

/** PostgREST over fetch: GETs answer from `tables` (filtered by eq. and in.), functions from `rpc`. Every call is kept. */
function serve(world: { tables?: Record<string, Row[]>; rpc?: Record<string, (body: any) => unknown> } = {}) {
  const calls: Call[] = [];
  const tables = world.tables ?? {};
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    const path = url.pathname.replace(/^\/rest\/v1\//, "");
    const text = typeof init?.body === "string" ? init.body : "";
    const call: Call = { method: (init?.method ?? "GET").toUpperCase(), path, params: url.searchParams, body: text ? JSON.parse(text) : undefined };
    calls.push(call);
    if (path.startsWith("rpc/")) {
      const fn = world.rpc?.[path.slice(4)];
      return Response.json(fn ? (fn(call.body) ?? null) : true);
    }
    if (call.method === "GET") {
      let rows = tables[path] ?? [];
      for (const [column, filter] of url.searchParams) {
        if (!rows.some((r) => column in r)) continue;
        if (filter.startsWith("eq.")) rows = rows.filter((r) => String(r[column]) === filter.slice(3));
        else if (filter.startsWith("in.(")) rows = rows.filter((r) => filter.slice(4, -1).split(",").map((v) => v.replace(/^"|"$/g, "")).includes(String(r[column])));
      }
      return Response.json(rows);
    }
    return Response.json([]);
  });
  return calls;
}
const writes = (calls: Call[], method: string, table: string) => calls.filter((c) => c.method === method && c.path === table);

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"], now: new Date("2026-10-27T15:00:00Z") }); // 11am in New York
  sendSms.mockClear().mockImplementation(async () => ({ sent: true, id: "sms-1" }));
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("a text Jobly writes", () => {
  /** The list of numbers told, as a stand-in that keeps what's written. `broken` fails every read and write. */
  const list = (told: string[] = [], broken = false) => {
    const kept = new Set(told);
    const from = () => {
      let row: Row | null = null;
      const eq: Row = {};
      const builder: Row = {
        select: () => builder,
        upsert: (value: Row) => ((row = value), builder),
        eq: (column: string, value: unknown) => ((eq[column] = value), builder),
        limit: () => builder,
        then: (resolve: (r: unknown) => unknown) => {
          if (broken) return Promise.resolve({ data: null, error: { message: "down" } }).then(resolve);
          if (row) kept.add(`${row.company_id}:${row.phone_key}`);
          return Promise.resolve({ data: row ? null : kept.has(`${eq.company_id}:${eq.phone_key}`) ? [{ phone_key: eq.phone_key }] : [], error: null }).then(resolve);
        },
      };
      return builder;
    };
    return { db: { from } as unknown as Db, kept };
  };
  const send = () => vi.fn(async (_body: string) => ({ sent: true, id: "SM1" }));

  it("says how to stop on the first one to a number, and not on the next", async () => {
    const { db, kept } = list();
    const out = send();
    await textWithStopLine(db, CO, "(512) 555-0100", "Acme Lawn: your visit is tomorrow at 9.", out);
    await textWithStopLine(db, CO, "+15125550100", "Acme Lawn: we're on our way.", out);
    expect(out.mock.calls.map((c) => c[0])).toEqual([`Acme Lawn: your visit is tomorrow at 9.\n\n${STOP}`, "Acme Lawn: we're on our way."]);
    expect([...kept]).toEqual([`${CO}:5125550100`]);
    // Another number, and the same number for another company, are told for themselves.
    await textWithStopLine(db, CO, "512-555-0199", "Hello", out);
    await textWithStopLine(db, "co-2", "512-555-0100", "Hello", out);
    expect(out.mock.calls.slice(2).map((c) => c[0])).toEqual([`Hello\n\n${STOP}`, `Hello\n\n${STOP}`]);
  });

  it("says it on every promotional one", async () => {
    const { db } = list([`${CO}:5125550100`]);
    const out = send();
    await textWithStopLine(db, CO, "512-555-0100", "20% off aeration this month.", out, { promotional: true });
    await textWithStopLine(db, CO, "512-555-0100", "20% off aeration this month.", out, { promotional: true });
    expect(out.mock.calls.map((c) => c[0])).toEqual([`20% off aeration this month.\n\n${STOP}`, `20% off aeration this month.\n\n${STOP}`]);
  });

  it("doesn't count a text that didn't go, so the next one still says it", async () => {
    const { db, kept } = list();
    const refused = vi.fn(async (_body: string) => ({ sent: false, reason: "The text provider refused it (400)." }));
    expect(await textWithStopLine(db, CO, "512-555-0100", "Hello", refused)).toMatchObject({ sent: false });
    expect([...kept]).toEqual([]);
  });

  it("leaves the business's own STOP wording alone, and still counts it", async () => {
    const { db, kept } = list();
    const out = send();
    await textWithStopLine(db, CO, "512-555-0100", "Acme Lawn: see you at 9. Text STOP to end.", out);
    expect(out.mock.calls[0]![0]).toBe("Acme Lawn: see you at 9. Text STOP to end.");
    expect(kept.size).toBe(1);
  });

  it("says it anyway when the list can't be read", async () => {
    const quiet = vi.spyOn(console, "error").mockImplementation(() => {});
    const out = send();
    expect(await textWithStopLine(list([], true).db, CO, "512-555-0100", "Hello", out)).toMatchObject({ sent: true });
    expect(out.mock.calls[0]![0]).toBe(`Hello\n\n${STOP}`);
    quiet.mockRestore();
  });
});

describe("a rule's text", () => {
  const ANA: Row = {
    id: ANA_ID, company_id: CO, display_name: "Ana Smith", email: "ana@example.com", phone: "(512) 555-0100", tags: [], status: "active", lead_source: null,
    review_opt_out: false, marketing_opt_out: false, sms_opt_out_at: null, reviewed_at: null,
  };
  const company: Row = {
    id: CO, name: "Acme Lawn", phone: "555-0100", email: "office@acme.example", website: null, timezone: "America/New_York", currency: "USD", trade_preset: "lawn_care",
    address: { line1: "1 Main St", city: "Oakridge", region: "VA", postal_code: "78701" }, settings: { marketing: { enabled: true } },
  };
  const visit = { id: "visit-1", company_id: CO, title: "Mowing", kind: "job", status: "scheduled", scheduled_on: "2026-10-28", starts_at: "2026-10-28T14:00:00Z", eta_at: null, job_id: "job-1", property_id: null, property: null, job: { client_id: ANA_ID, kind: "one_off" }, request: null };
  const run = (over: Row = {}) => ({ id: 7, company_id: CO, rule_id: "rule-1", subject_type: "visit", subject_id: "visit-1", activity_id: null, result: [], claim_token: "claim-1", ...over });
  const rule = (over: Row = {}) => ({ id: "rule-1", company_id: CO, name: "Reminder", trigger: "visit.reminder", enabled: true, delay_minutes: 0, conditions: [], actions: [{ type: "send_sms", body: "Hi {{client.first_name}}, your visit is tomorrow." }], run_count: 0, ...over });

  it("says how to stop the first time, keeps that, and doesn't say it again", async () => {
    let calls = serve({ tables: { companies: [company], automation_rules: [rule()], visits: [visit], clients: [ANA] } });
    expect(await executeRun(env, adminClient(env), run(), env.APP_URL!)).toBe("done");
    expect(sendSms.mock.calls[0]![1].body).toBe(`Hi Ana, your visit is tomorrow.\n\n${STOP}`);
    expect(writes(calls, "POST", "sms_told").map((c) => c.body)).toEqual([{ company_id: CO, phone_key: "5125550100" }]);
    // The copy on her timeline is the message itself.
    expect(writes(calls, "POST", "messages")[0]!.body.body).toBe("Hi Ana, your visit is tomorrow.");

    calls = serve({ tables: { companies: [company], automation_rules: [rule()], visits: [visit], clients: [ANA], sms_told: [{ company_id: CO, phone_key: "5125550100" }] } });
    expect(await executeRun(env, adminClient(env), run(), env.APP_URL!)).toBe("done");
    expect(sendSms.mock.calls[1]![1].body).toBe("Hi Ana, your visit is tomorrow.");
    expect(writes(calls, "POST", "sms_told")).toEqual([]);
  });

  it("always says it on a text a business added to a marketing campaign", async () => {
    const reengage = rule({ trigger: "client.inactive", template_key: "reengage", actions: [{ type: "send_sms", body: "We miss you, {{client.first_name}}. 10% off your next visit." }] });
    serve({
      tables: { companies: [company], automation_rules: [reengage], clients: [ANA], sms_told: [{ company_id: CO, phone_key: "5125550100" }], visits: [], autopay_authorizations: [] },
    });
    expect(await executeRun(env, adminClient(env), run({ subject_type: "client", subject_id: ANA_ID }), env.APP_URL!)).toBe("done");
    expect(sendSms.mock.calls[0]![1].body).toBe(`We miss you, Ana. 10% off your next visit.\n\n${STOP}`);
  });
});
