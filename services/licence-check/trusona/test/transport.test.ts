import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { it } from "node:test";
import { bindsDocumentSubject, type CompareRequest } from "@kenshiki-labs/licence-check";
import { executeTrusonaComparison, trusonaAdapter, trusonaConnection, trusonaProfile,
  type TrusonaConnection, type TrusonaRuntime } from "../src/index.js";

const fixture = JSON.parse(readFileSync("../contracts/trusona-adapter-vectors.json", "utf8")).vectors[0];
const id = fixture.supplier.create.body.id as string;
const terminal = fixture.supplier.reads[0].body;
function request(now = 1_000): CompareRequest {
  const value = structuredClone(fixture.request) as CompareRequest;
  return { ...value, expires_at: new Date(now + 30_000).toISOString() };
}
function connection(): TrusonaConnection {
  const value = trusonaConnection("synthetic-no-provider-authority", {});
  assert.ok(value);
  return value;
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status });
function scripted(replies: (() => Response | Promise<Response>)[], start = 1_000) {
  let now = start;
  const calls: { url: string; init: RequestInit | undefined }[] = [];
  const runtime: TrusonaRuntime = {
    now: () => now,
    sleep: async (ms) => { now += ms; },
    fetch: async (url, init) => {
      calls.push({ url: String(url), init });
      const next = replies.shift();
      assert.ok(next, "Unexpected retry/request");
      return next();
    },
  };
  return { runtime, calls, setNow: (value: number) => { now = value; } };
}

it("refuses forged or copied connections before any dispatch", async () => {
  const scenario = scripted([]);
  for (const value of [{ key: "secret", baseURL: "https://unreviewed.invalid" }, { ...connection() }]) {
    const result = await executeTrusonaComparison(value as TrusonaConnection, request(), trusonaProfile("zip5"), 10_000, scenario.runtime);
    assert.deepEqual(result, { kind: "not_dispatched" });
  }
  assert.equal(scenario.calls.length, 0);
  assert.ok(Object.isFrozen(connection()));
});

it("refuses invalid/expired deadlines and mismatched profiles without supplier calls", async () => {
  const scenario = scripted([]);
  for (const deadline of [NaN, Infinity, -Infinity, 999, 1_000, 1_000.5, Number.MAX_SAFE_INTEGER+1])
    assert.deepEqual(await executeTrusonaComparison(connection(), request(), trusonaProfile("zip5"), deadline, scenario.runtime),
      { kind: "not_dispatched" });
  assert.deepEqual(await executeTrusonaComparison(connection(), request(-30_000), trusonaProfile("zip5"), 10_000, scenario.runtime),
    { kind: "not_dispatched" });
  assert.deepEqual(await executeTrusonaComparison(connection(), { ...request(), profile_version: "other" }, trusonaProfile("zip5"),
    10_000, scenario.runtime), { kind: "not_dispatched" });
  assert.equal(scenario.calls.length, 0);
});

for (const clock of [[1_000, 9_999], [1_000, 10_000], [1_000, 10_001], [1_000, 9_999, 10_000]])
  it(`preserves dispatch knowledge across create clock ${clock.join(" -> ")}`, async () => {
    let clockReads = 0;
    let calls = 0;
    const runtime: TrusonaRuntime = {
      now: () => clock[Math.min(clockReads++, clock.length - 1)]!,
      sleep: async () => {},
      fetch: async () => { calls++; throw new Error("synthetic lost create"); },
    };
    const execution = await trusonaAdapter(connection(), "zip5", runtime).execute(request(), 10_000);
    const attempted = clock.at(-1)! < 10_000;
    assert.deepEqual(execution, attempted
      ? { kind: "outcome_unknown", cause: "create_lost", supplierReference: null }
      : { kind: "not_dispatched" });
    assert.equal(calls, attempted ? 1 : 0);
  });

it("retains create uncertainty when expiry prevents the first retrieval dispatch", async () => {
  let created = false;
  let afterCreateReads = 0;
  let calls = 0;
  const runtime: TrusonaRuntime = {
    // POST completion and loop admission are within deadline; GET preflight is expired.
    now: () => created && ++afterCreateReads >= 3 ? 10_000 : 1_000,
    sleep: async () => {},
    fetch: async (_url, init) => {
      calls++;
      assert.equal(init?.method, "POST");
      created = true;
      return json({ id }, 201);
    },
  };
  assert.deepEqual(await trusonaAdapter(connection(), "zip5", runtime).execute(request(), 10_000),
    { kind: "outcome_unknown", cause: "deadline", supplierReference: id });
  assert.equal(calls, 1);
});

for (const status of [301, 302, 401, 403, 422, 429, 500])
  it(`never retries create status ${status} or follows a redirect`, async () => {
    const scenario = scripted([() => json({ diagnostic: "must not escape" }, status)]);
    const result = await executeTrusonaComparison(connection(), request(), trusonaProfile("zip5"), 10_000, scenario.runtime);
    assert.equal(result.kind, "supplier_response_invalid");
    assert.equal(scenario.calls.length, 1);
    assert.equal(scenario.calls[0]!.init?.redirect, "manual");
    assert.ok(!JSON.stringify(result).includes("must not escape"));
  });

for (const stage of ["create", "retrieve"])
  it(`lost ${stage} remains outcome_unknown with one create only`, async () => {
    const lost = () => { throw new Error("private supplier failure"); };
    const scenario = scripted(stage === "create" ? [lost] : [() => json({ id }, 201), lost]);
    const result = await executeTrusonaComparison(connection(), request(), trusonaProfile("zip5"), 10_000, scenario.runtime);
    assert.equal(result.kind, "outcome_unknown");
    assert.equal(scenario.calls.filter(call => call.init?.method === "POST").length, 1);
    assert.ok(!JSON.stringify(result).includes("private"));
  });

for (const kind of ["oversized", "invalid-json", "invalid-utf8", "stream-failure"])
  it(`bounds and rejects ${kind} supplier response bodies`, async () => {
    const response = () => {
      if (kind === "stream-failure") return new Response(new ReadableStream({ start(controller) { controller.error(new Error("secret")); } }), { status: 201 });
      const bytes = kind === "invalid-utf8" ? new Uint8Array([0xff]) : kind === "oversized" ? "x".repeat(65_537) : "{invalid";
      return new Response(bytes, { status: 201 });
    };
    const scenario = scripted([response]);
    const result = await executeTrusonaComparison(connection(), request(), trusonaProfile("zip5"), 10_000, scenario.runtime);
    assert.notEqual(result.kind, "result");
    assert.equal(scenario.calls.length, 1);
    assert.ok(!JSON.stringify(result).includes("secret"));
  });

it("does not accept a terminal response arriving at or after the original deadline", async () => {
  for (const now of [10_000, 10_001]) {
    const scenario = scripted([() => json({ id }, 201), () => { scenario.setNow(now); return json(terminal); }]);
    const result = await executeTrusonaComparison(connection(), request(), trusonaProfile("zip5"), 10_000, scenario.runtime);
    assert.equal(result.kind, "outcome_unknown");
    assert.equal(scenario.calls.length, 2);
  }
});

it("authorization expiry and profile processing limit can only shorten the supplied deadline", async () => {
  for (const expiry of [2_000, 100_000]) {
    const end = Math.min(expiry, 31_000);
    const scenario = scripted([() => json({ id }, 201), () => { scenario.setNow(end); return json(terminal); }]);
    const req = { ...request(), expires_at: new Date(expiry).toISOString() };
    const result = await executeTrusonaComparison(connection(), req, trusonaProfile("zip5"), 100_000, scenario.runtime);
    assert.equal(result.kind, "outcome_unknown");
  }
});

it("aborts a stalled exchange and preserves dispatch uncertainty", async () => {
  let signal: AbortSignal | null | undefined;
  const runtime: TrusonaRuntime = {
    now: () => 1_000, sleep: async () => {},
    fetch: async (_url, init) => new Promise((_resolve, reject) => {
      signal = init?.signal;
      signal?.addEventListener("abort", () => reject(new Error("synthetic timeout")), { once: true });
    }),
  };
  const result = await executeTrusonaComparison(connection(), request(), trusonaProfile("zip5"), 1_030, runtime);
  assert.equal(result.kind, "outcome_unknown");
  assert.equal(signal?.aborted, true);
});

it("snapshots the admitted request and policy across awaited dispatch", async () => {
  const req = request();
  const original = structuredClone(req);
  const scenario = scripted([() => {
    Object.assign(req, { operation_id: "replacement-operation" });
    Object.assign(req.evidence, { capture_reference: "replacement-capture", request_revision: "replacement-revision" });
    Object.assign(req.evidence.document.address.postal_code, { zip4: "9999" });
    return json({ id }, 201);
  }, () => json({ ...terminal, dmvMatches: { ...terminal.dmvMatches, zip4: false } })]);
  const adapter = trusonaAdapter(connection(), "full_available", scenario.runtime);
  assert.ok(Object.isFrozen(adapter.profile) && Object.isFrozen(adapter.profile.provider));
  assert.throws(() => { adapter.profile.postal_policy = "zip5"; }, TypeError);
  const execution = await adapter.execute(req, 10_000);
  assert.equal(execution.kind, "result");
  if (execution.kind !== "result") throw new Error("Expected result");
  assert.equal(execution.result.operation_id, original.operation_id);
  assert.equal(execution.result.capture_reference, original.evidence.capture_reference);
  assert.equal(execution.result.request_revision, original.evidence.request_revision);
  assert.equal(execution.result.evaluation.postal_policy, "full_available");
  assert.ok(execution.result.evaluation.required_checks.includes("zip4"));
  assert.equal(bindsDocumentSubject(execution.result, req, adapter.profile), false);
  assert.equal(bindsDocumentSubject(execution.result, original, adapter.profile), false, "ZIP4 mismatch blocks binding");
  assert.equal(scenario.calls.length, 2);
});

for (const completedAt of ["2026-10-11T24:00:00Z", "2026-02-30T12:00:00Z", 1234, null])
  it(`never confirms malformed completion ${String(completedAt)}`, async () => {
    const scenario = scripted([() => json({ id }, 201), () => json({ ...terminal, completedAt })]);
    const execution = await trusonaAdapter(connection(), "zip5", scenario.runtime).execute(request(), 10_000);
    assert.equal(execution.kind, "result");
    if (execution.kind !== "result") throw new Error("Expected result");
    assert.equal(execution.supplierConfirmed, false);
    assert.equal(execution.supplierCompletedAtMs, null);
  });

it("integrates the public adapter through real loopback HTTP, translation and core binding", async (t) => {
  const requests: { method: string; url: string; body: unknown; authorization: string | undefined }[] = [];
  const server = createServer(async (req, res) => {
    let text = "";
    for await (const chunk of req) text += String(chunk);
    requests.push({ method: req.method!, url: req.url!, body: text ? JSON.parse(text) : null, authorization: req.headers.authorization });
    res.setHeader("content-type", "application/json");
    res.setHeader("cache-control", "no-store");
    res.writeHead(req.method === "POST" ? 201 : 200);
    res.end(JSON.stringify(req.method === "POST" ? { id } : terminal));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise<void>((resolve, reject) => { server.close(error => error ? reject(error) : resolve()); server.closeAllConnections(); }));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const local = trusonaConnection("pulse-licence-e2e-local-only", {
    deploymentEnvironment: "local", localTestBaseURL: `http://127.0.0.1:${address.port}`,
  });
  assert.ok(local);
  const adapter = trusonaAdapter(local, "full_available");
  const req = request(Date.now());
  const execution = await adapter.execute(req, Date.now()+5_000);
  assert.equal(execution.kind, "result");
  if (execution.kind !== "result") throw new Error("Expected result");
  assert.equal(execution.supplierConfirmed, true);
  assert.equal(execution.result.evaluation.status, "incomplete");
  assert.equal(execution.result.checks.street_line1.comparison_scope, "unqualified");
  assert.equal(bindsDocumentSubject(execution.result, req, adapter.profile), true);
  assert.deepEqual(requests.map(r => [r.method, r.url]), [["POST", "/api/v1/id_verifications"], ["GET", `/api/v1/id_verifications/${id}`]]);
  assert.equal((requests[0]!.body as {transactionId:string}).transactionId, req.operation_id);
  assert.equal(requests[0]!.authorization, "Bearer pulse-licence-e2e-local-only");
});
