import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { CHECK_FIELDS, bindsDocumentSubject, requiredChecks } from "../src/index.js";
import type { Check, CheckField, CompareRequest, CompareResult, ComparisonProfile, LicenseDocument } from "../src/index.js";

const document: LicenseDocument = {
  document_type: "driver_license", issuer_iin: "636045", issuing_jurisdiction: "WA", document_number: "D1234567",
  family_name: { value: "TESTERSON", truncation: "complete" }, given_name: { value: "ALEX", truncation: "complete" },
  birth_date: "1990-01-01",
  address: { street_line1: "100 EXAMPLE WAY", city: "SAMPLE CITY", state: "OR",
    postal_code: { zip5: "97000", extension_state: "present", zip4: "1234" } },
};
const profile: ComparisonProfile = {
  profile_version: "trusona-dldv-2", policy_version: "pulse-dldv-03-05-street-observation-1", postal_policy: "zip5",
  max_processing_ms: 30_000,
  provider: { provider_id: "trusona", product: "Driver License Verification API", api_version: "1.0.0",
    adapter_version: "trusona-id-verification-v1-draft-1", qualification_revision: "unqualified" },
};
function request(changes: Partial<LicenseDocument> = {}): CompareRequest {
  return { contract_version: "pulse.dldv.v1", operation_id: "11111111-1111-4111-8111-111111111111",
    profile_version: profile.profile_version, expires_at: "2026-10-22T00:01:00Z",
    evidence: { capture_reference: "22222222-2222-4222-8222-222222222222", request_revision: "1",
      decoder_version: "synthetic", parser_version: "synthetic", normalization_version: "pulse.aamva-normalization.v1",
      corrected_fields: [], document: { ...document, ...changes }, captured_at: "2026-10-22T00:00:00Z" } };
}
const matched: Check = { submitted: true, compared: true, outcome: "match", comparison_scope: "unqualified", reason_code: "matched" };
const mismatched: Check = { submitted: true, compared: true, outcome: "mismatch", comparison_scope: "unqualified", reason_code: "mismatched" };
const absent: Check = { submitted: false, compared: false, outcome: "not_checked", comparison_scope: "not_applicable", reason_code: "not_present" };
function result(forRequest: CompareRequest, checks: Partial<Record<CheckField, Check>> = {}): CompareResult {
  const required = requiredChecks(forRequest.evidence.document, profile.postal_policy);
  const all = Object.fromEntries(CHECK_FIELDS.map((field) => [field, required.includes(field) ? matched : absent])) as
    Record<CheckField, Check>;
  return { contract_version: "pulse.dldv.v1", operation_id: forRequest.operation_id, profile_version: profile.profile_version,
    capture_reference: forRequest.evidence.capture_reference, request_revision: "1", completed_at: "2026-10-22T00:00:05Z",
    provider: { ...profile.provider }, checks: { ...all, ...checks },
    evaluation: { status: "incomplete", policy_version: profile.policy_version, postal_policy: profile.postal_policy,
      required_checks: required, unsatisfied_checks: [], incomplete_checks: required } };
}

describe("DLDV-03 required checks", () => {
  it("requires the core fields for zip5 and ignores ZIP+4 under that policy", () => {
    assert.deepEqual(requiredChecks(document, "zip5"),
      ["document_number", "family_name", "given_name", "birth_date", "street_line1", "city", "address_state", "zip5"]);
  });
  it("adds a present second line, and ZIP+4 only when full_available and present", () => {
    const withLine2 = { ...document, address: { ...document.address, street_line2: "UNIT 4" } };
    assert.ok(requiredChecks(withLine2, "zip5").includes("street_line2"));
    assert.ok(requiredChecks(document, "full_available").includes("zip4"));
    const padded = { ...document, address: { ...document.address,
      postal_code: { zip5: "97000", extension_state: "unknown_padding" as const, zip4: null } } };
    assert.ok(!requiredChecks(padded, "full_available").includes("zip4"));
  });
});

describe("subject-binding policy", () => {
  it("binds when every required check is an observed match", () => {
    const value = request();
    assert.equal(bindsDocumentSubject(result(value), value, profile), true);
  });
  it("binds through an observed first-street-line mismatch only", () => {
    const value = request();
    assert.equal(bindsDocumentSubject(result(value, { street_line1: mismatched }), value, profile), true);
    for (const field of ["family_name", "given_name", "birth_date", "document_number", "city", "address_state", "zip5"] as const)
      assert.equal(bindsDocumentSubject(result(value, { [field]: mismatched }), value, profile), false, field);
  });
  it("refuses a required check that was not compared or not unqualified", () => {
    const value = request();
    assert.equal(bindsDocumentSubject(result(value, { city: { ...matched, compared: null } }), value, profile), false);
    assert.equal(bindsDocumentSubject(result(value, { city: { ...matched, comparison_scope: "not_applicable" } }), value, profile), false);
    assert.equal(bindsDocumentSubject(result(value, { street_line1: { ...mismatched, compared: null } }), value, profile), false);
  });
  it("refuses a result for another profile, policy or provider", () => {
    const value = request();
    const base = result(value);
    assert.equal(bindsDocumentSubject({ ...base, profile_version: "trusona-dldv-1" }, value, profile), false);
    assert.equal(bindsDocumentSubject({ ...base, evaluation: { ...base.evaluation, policy_version: "other" } }, value, profile), false);
    assert.equal(bindsDocumentSubject({ ...base, provider: { ...base.provider, provider_id: "persona" } }, value, profile), false);
  });
  it("refuses required checks that are not exactly DLDV-03's for the document", () => {
    const value = request();
    const base = result(value);
    const required = base.evaluation.required_checks;
    const lists: CheckField[][] = [required.slice(1), [...required, "zip4"], [...required.slice(1), required[0]!, required[0]!]];
    for (const list of lists)
      assert.equal(bindsDocumentSubject({ ...base, evaluation: { ...base.evaluation, required_checks: list } }, value, profile),
        false, list.join(","));
    const withLine2 = request({ address: { ...document.address, street_line2: "UNIT 4" } });
    assert.equal(bindsDocumentSubject(result(value), withLine2, profile), false);
  });
});

describe("bound request and configured postal policy", () => {
  for (const field of ["operation_id", "capture_reference", "request_revision", "contract_version"] as const)
    it(`refuses another ${field}`, () => {
      const req = request();
      const foreign = { ...result(req), [field]: "foreign" } as CompareResult;
      assert.equal(bindsDocumentSubject(foreign, req, profile), false);
    });
  it("refuses a result that downgrades the configured ZIP+4 policy", () => {
    const req = request();
    assert.equal(bindsDocumentSubject(result(req), req, { ...profile, postal_policy: "full_available" }), false);
  });
});
