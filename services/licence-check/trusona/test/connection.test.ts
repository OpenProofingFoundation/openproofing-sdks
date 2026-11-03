/// Ported from pulse-worker src/trusonaLocalConnection.test.ts: the local E2E stub cannot redirect
/// production credentials. The host's stage now arrives as TrusonaHostStage rather than Worker env.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { TRUSONA_BASE_URL, trusonaConnection } from "../src/index.js";

describe("The Trusona local E2E stub cannot redirect production credentials", () => {
  for (const stage of [undefined, "production", "development", "LOCAL", "local "])
    it(`keeps the fixed origin in stage ${String(stage)}`, () => {
      assert.deepEqual(trusonaConnection("real-shaped-credential", {
        deploymentEnvironment: stage, localTestBaseURL: "http://127.0.0.1:9123",
      }), { key: "real-shaped-credential", baseURL: TRUSONA_BASE_URL });
    });
  it("allows only a literal loopback stub with the synthetic credential in local stage", () => {
    assert.deepEqual(trusonaConnection("pulse-licence-e2e-local-only", {
      deploymentEnvironment: "local", localTestBaseURL: "http://127.0.0.1:9123",
    }), { key: "pulse-licence-e2e-local-only", baseURL: "http://127.0.0.1:9123" });
  });
  it("never sends a real credential to the local stub", () => {
    assert.equal(trusonaConnection("real-shaped-credential", {
      deploymentEnvironment: "local", localTestBaseURL: "http://127.0.0.1:9123",
    }), null);
  });
  for (const baseURL of ["https://127.0.0.1:9123", "http://localhost:9123", "http://127.1:9123", "http://2130706433:9123",
    "http://127.0.0.1.evil.test:9123", "http://127.0.0.1:9123/path", "http://127.0.0.1:9123?target=evil",
    "http://127.0.0.1:9123#evil", "http://user@127.0.0.1:9123", "http://[::1]:9123",
    "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:99999", "http://127.0.0.1:9123/",
    "http://127.0.0.1:9123\n", "http://127.0.0.1:9123\r", " http://127.0.0.1:9123", "http://127.0.0.1:09123", ""])
    it(`rejects ambiguous or non-loopback address ${JSON.stringify(baseURL)}`, () => {
      assert.equal(trusonaConnection("pulse-licence-e2e-local-only", {
        deploymentEnvironment: "local", localTestBaseURL: baseURL,
      }), null);
    });
});
