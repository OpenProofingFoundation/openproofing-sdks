import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { it } from "node:test";
import type { CompareRequest } from "@kenshiki-labs/licence-check";
import { bindsSubject, encodeTrusonaRequest, executeTrusonaComparison, trusonaConnection, trusonaProfile,
  type TrusonaRuntime } from "../src/index.js";

// Paths resolve from package cwd, independent of transpiled test output layout.
const bytes = readFileSync("../contracts/trusona-adapter-vectors.json");
const manifest = JSON.parse(readFileSync("../contracts/provenance.json", "utf8"));
assert.equal(createHash("sha256").update(bytes).digest("hex"), manifest.files["trusona-adapter-vectors.json"]);
const suite = JSON.parse(bytes.toString());
assert.equal(suite.contract.sha256, manifest.files["pulse-dldv.openapi.yaml"]);
assert.equal(suite.supplier_source_sha256, manifest.files["trusona-id-verification-v1.source.yaml"]);
assert.ok(suite.vectors.length > 0);
for (const vector of suite.vectors) {
  it(`shared pinned vector: ${vector.id}`, async () => {
    const request = vector.request as CompareRequest;
    const profile = trusonaProfile(vector.postal_policy);
    let now = Date.parse(suite.clock_start);
    let creates = 0, reads = 0;
    const runtime: TrusonaRuntime = {
      now: () => now,
      sleep: async (ms) => { now += ms; },
      fetch: async (_url, init) => {
        const create = init?.method === "POST";
        if (create) {
          creates++;
          assert.deepEqual(JSON.parse(String(init?.body)), vector.expect.supplier_request);
        }
        const reply = create ? vector.supplier.create
          : vector.supplier.reads[Math.min(reads++, vector.supplier.reads.length-1)];
        if (!reply) throw new Error("synthetic lost response; must not escape");
        return new Response(JSON.stringify(reply.body), { status: reply.status });
      },
    };
    assert.deepEqual(encodeTrusonaRequest(request).body, vector.expect.supplier_request);
    const connection = trusonaConnection("synthetic-no-provider-authority", {});
    assert.ok(connection);
    const execution = await executeTrusonaComparison(connection, request, profile, Date.parse(request.expires_at), runtime);
    assert.equal(creates, 1, "Create must never retry");
    if (vector.expect.reply.kind === "result") {
      assert.equal(execution.kind, "result");
      if (execution.kind !== "result") throw new Error("Expected result");
      const { completed_at, ...result } = execution.result;
      assert.ok(completed_at);
      assert.deepEqual(result, vector.expect.reply.result);
      assert.equal(bindsSubject(execution.result, execution.retrieved, request, profile), vector.expect.binds_subject);
    } else {
      assert.equal(execution.kind, vector.expect.reply.code);
    }
  });
}
