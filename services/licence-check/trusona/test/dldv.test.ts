/// The Trusona adapter against the Pulse DLDV contract rules: the same cases the reference
/// implementation runs (pulse-compliance tools/dldv_trusona_adapter.py selftest), ported from
/// pulse-worker src/trusonaDldv.test.ts. Synthetic values only.
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { CompareRequest, LicenseDocument } from "@kenshiki-labs/licence-check";
import { bindsSubject, encodeTrusonaRequest, translateTrusonaResult, trusonaProfile } from "../src/index.js";

const VID = "00000000-0000-4000-8000-0000000000aa";

function request(document: Partial<LicenseDocument> = {}): CompareRequest {
  const name = { value: "TESTNAME", truncation: "complete" as const };
  return {
    contract_version: "pulse.dldv.v1", operation_id: "00000000-0000-4000-8000-000000000001",
    profile_version: "trusona-dldv-2", expires_at: "2026-10-11T12:00:30Z",
    evidence: {
      capture_reference: "00000000-0000-4000-8000-000000000002", request_revision: "r1", decoder_version: "d",
      parser_version: "p", normalization_version: "n", corrected_fields: [], captured_at: "2026-10-11T12:00:00Z",
      document: {
        document_type: "state_id", issuer_iin: "636000", issuing_jurisdiction: "VA", document_number: "TEST0001",
        family_name: name, given_name: { ...name }, birth_date: "1990-01-02",
        address: { street_line1: "1 EXAMPLE WAY", street_line2: "UNIT 2", city: "TESTVILLE", state: "MD",
          postal_code: { zip5: "12345", extension_state: "present", zip4: "6789" } },
        ...document,
      },
    },
  };
}

const allTrue = { firstName: true, lastName: true, dateOfBirth: true, documentNumber: true, documentType: true,
  address1: true, address2: true, city: true, state: true, zipCode: true, zip4: true };
const done = (delta: Record<string, unknown> = {}): Record<string, unknown> => ({ id: VID,
  completedAt: "2026-10-11T12:00:03Z", dmvStatus: "SUCCESS", dmvMatches: allTrue, ...delta });

function translate(retrieved: Record<string, unknown>, req = request(), policy: "zip5" | "full_available" = "full_available") {
  return translateTrusonaResult(req, trusonaProfile(policy), encodeTrusonaRequest(req), retrieved, "2026-10-11T12:00:04Z");
}

describe("trusona DLDV adapter", () => {
  it("sends the issuing state as documentJurisdiction, the address state separately, DMV only", () => {
    const { body } = encodeTrusonaRequest(request());
    assert.deepEqual(body.verifiers, { dmv: { documentCountry: "US", documentJurisdiction: "VA", documentCategory: "ID",
      documentNumber: "TEST0001" } });
    for (const [key, value] of Object.entries({ transactionId: "00000000-0000-4000-8000-000000000001", state: "MD",
      zipCode: "12345", zip4: "6789", address2: "UNIT 2" })) assert.equal(body[key], value, key);
    assert.ok(!Object.hasOwn(body, "callbackUrl"));
  });

  for (const [field, value, key, expected] of [
    ["eye_color", "BLU", "eyeColor", "BLU"], ["height", { value: 70, unit: "in" }, "height", "510"],
    ["weight", { value: 150, unit: "lb" }, "weight", "150"], ["recorded_sex", "1", "sex", "M"], ["recorded_sex", "2", "sex", "F"],
  ] as const) it(`encodes ${field} exactly`, () => {
    assert.equal(encodeTrusonaRequest(request({ [field]: value })).body.verifiers.dmv[key], expected);
  });

  for (const [field, value] of [
    ["recorded_sex", "9"], ["eye_color", "XYZ"], ["height", { value: 178, unit: "cm" }], ["height", { value: 70.5, unit: "in" }],
    ["weight", { value: 95, unit: "lb" }], ["weight", { value: 70, unit: "kg" }],
  ] as const) it(`reports ${field} ${JSON.stringify(value)} unsupported and never coerces it`, () => {
    const encoded = encodeTrusonaRequest(request({ [field]: value }));
    assert.equal(encoded.unsupported.has(field), true);
    assert.deepEqual(translate(done(), request({ [field]: value })).checks[field], { submitted: false, compared: false,
      outcome: "unsupported", comparison_scope: "not_applicable", reason_code: "unsupported_field" });
  });

  it("keeps observed matches unqualified, so SUCCESS never becomes satisfied", () => {
    const result = translate(done());
    assert.deepEqual(result.checks.street_line1, { submitted: true, compared: true, outcome: "match",
      comparison_scope: "unqualified", reason_code: "matched" });
    assert.equal(result.evaluation.status, "incomplete");
    assert.deepEqual(result.evaluation.unsatisfied_checks, []);
    assert.ok(result.evaluation.required_checks.includes("street_line2") && result.evaluation.required_checks.includes("zip4"));
    assert.deepEqual(result.evaluation.incomplete_checks, result.evaluation.required_checks);
    assert.equal(result.checks.eye_color.outcome, "not_checked");
    assert.ok(!translate(done(), request(), "zip5").evaluation.required_checks.includes("zip4"));
  });

  it("preserves a mismatch without promoting it to an identity-level failure", () => {
    const result = translate(done({ dmvMatches: { ...allTrue, address1: false } }));
    assert.equal(result.checks.street_line1.outcome, "mismatch");
    assert.deepEqual(result.evaluation.unsatisfied_checks, []);
  });

  it("reports an omitted result as omitted, never repaired", () => {
    const { city: _city, ...rest } = allTrue;
    assert.deepEqual(translate(done({ dmvMatches: rest })).checks.city, { submitted: true, compared: null,
      outcome: "indeterminate", comparison_scope: "unqualified", reason_code: "omitted_result" });
  });

  for (const value of [null, "true", 0, 1, {}, []]) it(`refuses a malformed boolean ${JSON.stringify(value)}`, () => {
    assert.equal(translate(done({ dmvMatches: { ...allTrue, city: value } })).checks.city.reason_code, "invalid_supplier_response");
  });

  for (const status of ["FAILURE", "FATAL"]) it(`never reads ${status} as a comparison`, () => {
    const check = translate(done({ dmvStatus: status })).checks.family_name;
    assert.equal(check.outcome, "indeterminate");
    assert.equal(check.reason_code, "comparison_scope_unknown");
  });

  for (const delta of [{ dmvStatus: "UNKNOWN" }, { completedAt: null }, { completedAt: "garbage" }, { dmvMatches: null }])
    it(`treats ${JSON.stringify(delta)} as an invalid supplier response`, () => {
      assert.equal(translate(done(delta)).checks.family_name.reason_code, "invalid_supplier_response");
    });

  it("never fills a DMV gap from the carrier result", () => {
    const result = translate(done({ dmvMatches: {}, mnoStatus: "SUCCESS", mnoMatches: { firstName: true } }));
    assert.equal(result.checks.given_name.reason_code, "omitted_result");
  });

  it("sends a suffix but invents no suffix comparison", () => {
    const req = request({ name_suffix: "JR" });
    assert.equal(encodeTrusonaRequest(req).body.suffix, "JR");
    assert.equal(translate(done({ dmvMatches: { ...allTrue, suffix: true } }), req).checks.name_suffix.reason_code, "omitted_result");
  });

  it("requires valid comparisons and matches for the remaining required fields", () => {
    assert.equal(bindsSubject(translate(done()), done(), request(), trusonaProfile("full_available")), true);
    const mismatch = done({ dmvMatches: { ...allTrue, zipCode: false } });
    assert.equal(bindsSubject(translate(mismatch), mismatch, request(), trusonaProfile("full_available")), false);
    const { address2: _a, ...noUnit } = allTrue;
    assert.equal(bindsSubject(translate(done({ dmvMatches: noUnit })), done({ dmvMatches: noUnit }), request(), trusonaProfile("full_available")), false);
    assert.equal(bindsSubject(translate(done({ dmvStatus: "FAILURE" })), done({ dmvStatus: "FAILURE" }), request(), trusonaProfile("full_available")), false);
  });
});

// Ported from pulse-worker src/trusonaStreetEncoding.test.ts. The Worker builds these documents
// through its barcode normalizer; the claim under test here is the adapter's: street lines reach
// Trusona's address1/address2 exactly as the document carries them.
describe("street lines to Trusona request mapping", () => {
  for (const { id, line1, line2 } of [
    { id: "separate unit", line1: "123 EXAMPLE AVE", line2: "APT 4B" },
    { id: "inline unit", line1: "123 EXAMPLE AVE APT 4B", line2: undefined },
    { id: "internal spaces", line1: "123  EXAMPLE AVE", line2: undefined },
    { id: "punctuation", line1: "123 EXAMPLE AVE.", line2: "UNIT #4" },
    { id: "post office box", line1: "PO BOX 123", line2: undefined },
  ]) it(`preserves the street shape: ${id}`, () => {
    const base = request().evidence.document;
    const address = { street_line1: line1, ...(line2 === undefined ? {} : { street_line2: line2 }), city: base.address.city,
      state: base.address.state, postal_code: base.address.postal_code };
    const encoded = encodeTrusonaRequest(request({ address }));
    assert.equal(encoded.body["address1"], line1);
    if (line2 === undefined) assert.ok(!Object.hasOwn(encoded.body, "address2"));
    else assert.equal(encoded.body["address2"], line2);
    assert.ok(!Object.hasOwn(encoded.body, "phoneNumber"));
    assert.ok(!Object.hasOwn(encoded.body.verifiers, "mno"));
  });
});
