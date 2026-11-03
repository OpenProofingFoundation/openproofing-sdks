"""Offline checks for proposed specification artifacts, not a production verifier.

All proof/receipt trust in the examples is synthetic. This program cannot verify
App Attest, contact an issuer/carrier, calibrate a model, or authorize enrollment.

Monorepo patch 2026-10-16: split offline parsing/policy checks and fixture helpers
into named responsibilities; frozen specifications, schemas and fixtures unchanged.
"""
import base64
from copy import deepcopy
from functools import partial
import hashlib
import json
from pathlib import Path
import re

from jsonschema import Draft7Validator, FormatChecker

HERE = Path(__file__).resolve().parent
DOMAIN = b"kenshiki:edge-verification:v3.1"


def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("nonfinite_json_number")


def finite(item, depth=0):
    import math
    if isinstance(item, (dict, list)) and depth > 16:
        raise ValueError("json_nesting_limit")
    if isinstance(item, str):
        item.encode("utf-8", errors="strict")
    if isinstance(item, float) and not math.isfinite(item):
        raise ValueError("nonfinite_json_number")
    if isinstance(item, dict):
        for key, child in item.items():
            key.encode("utf-8", errors="strict")
            finite(child, depth+1)
    if isinstance(item, list):
        for child in item:
            finite(child, depth+1)


def parse(text):
    value = json.loads(text, object_pairs_hook=reject_duplicates, parse_constant=reject_constant)
    # JSON exponents such as 1e999 are also nonfinite in common JSON runtimes.
    finite(value)
    return value


def b64url(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def decode_canonical(value, size=None):
    raw = base64.urlsafe_b64decode(value + "=" * ((-len(value)) % 4))
    if b64url(raw) != value or (size is not None and len(raw) != size):
        raise ValueError("noncanonical_or_wrong_size_base64url")
    return raw


def request_hash(challenge, payload_json):
    return b64url(hashlib.sha256(DOMAIN + b"\0" + challenge.encode("ascii")
                                 + b"\0" + payload_json.encode("utf-8")).digest())


def schemas():
    result = []
    for name in ("payload.schema.json", "ios-envelope.schema.json"):
        document = parse((HERE / "contracts" / name).read_text())
        Draft7Validator.check_schema(document)
        result.append(Draft7Validator(document, format_checker=FormatChecker()))
    return result


def _assess_replay(envelope, server):
    prior = server.get('priorResult')
    envelope_digest = hashlib.sha256(json.dumps(envelope, sort_keys=True,
                                              separators=(",", ":")).encode()).hexdigest()
    if prior is not None:
        if (server["replayReadAllowed"] and prior["envelopeDigest"] == envelope_digest
                and prior["retainedUntil"] > server["now"]):
            return "REPLAY_OF_FIXTURE_RESULT", "no_new_action_or_validity"
        return "REFUSE", "replay_not_exact_or_not_authorized"
    return None


def _assess_proof(payload, envelope, server):
    proof = envelope['appAttestAssertion']
    if (not server["proofVerified"] or proof["keyId"] != server["registeredKeyId"]
            or server["proofEnvironment"] != server["expectedEnvironment"]):
        return "REFUSE", "proof_unverified_or_wrong_binding"
    if (envelope["challenge"] != server["challenge"] or server["challengeConsumed"]
            or server["now"] >= server["challengeExpiresAt"]):
        return "REFUSE", "challenge_invalid_or_expired"
    if server["assertionCounter"] <= server["storedCounter"]:
        return "RETRY", "counter_not_advancing"
    if (payload["artifacts"] != server["allowedArtifacts"]
            or payload["policyProfile"] != server["policyProfile"]):
        return "REFUSE", "unapproved_policy_or_artifact"
    if payload["issuedAt"] > server["now"] or payload["issuedAt"] < server["attemptStartedAt"]:
        return "REFUSE", "payload_time_outside_attempt"
    return None


def _assess_capture(payload, server):
    front, back = payload["capture"]["front"], payload["capture"]["back"]
    portrait = payload["capture"]["portrait"]
    path = payload["credential"]["path"]
    if path == "physical_id1":
        if front["captureId"] == back["captureId"]:
            return "REFUSE", "front_back_capture_alias"
        if portrait["sourceSha256"] != front["sha256"]:
            return "REFUSE", "portrait_source_mismatch"
    trusted = server["trustedEvidence"]
    if not trusted["authenticated"]:
        return "REFUSE", "evidence_unverified"
    if any(payload[key] != trusted[key] for key in ("capture", "evidence", "credential", "outcomes", "artifacts")):
        return "REFUSE", "evidence_graph_mismatch"
    admission = trusted["admission"]
    if (admission["selfieCaptureId"] != payload["capture"]["selfie"]["captureId"]
            or admission["selfieSha256"] != payload["capture"]["selfie"]["sha256"]
            or admission["assessment"] != "live"):
        return "REFUSE", "selfie_admission_not_bound_or_live"
    return None


def _assess_receipt(kind, identifier, server, expected_binding, front, back, payload, portrait):
    receipt = server["receipts"].get(identifier)
    if receipt is None or receipt["kind"] != kind or not receipt["verified"]:
        return "REFUSE", "receipt_missing_or_unverified"
    if (receipt["binding"] != expected_binding
            or receipt["expiresAt"] <= server["now"]):
        return "REFUSE", "receipt_binding_or_freshness"
    if kind == "issuer" and (receipt["front"] != front or receipt["back"] != back):
        return "REFUSE", "issuer_capture_mismatch"
    if kind == "credential" and (receipt["reportSha256"] != payload["credential"]["reportSha256"]
            or receipt["portraitSourceSha256"] != portrait["sourceSha256"]):
        return "REFUSE", "credential_report_or_portrait_mismatch"
    if receipt["outcome"] in ("contradicted", "fail"):
        return "REJECT", "service_contradiction"
    # This is the example complete-signals profile, not current production policy.
    if receipt["outcome"] not in server["allowedServiceOutcomes"][kind]:
        return "INCOMPLETE", "required_service_unavailable"
    return None


def _assess_receipts(payload, server):
    front, back = payload['capture']['front'], payload['capture']['back']
    portrait = payload['capture']['portrait']
    path = payload['credential']['path']
    expected_binding = dict(server["session"], subjectDigest=server["expectedSubjectDigest"])
    checks = [("phone", payload["services"]["phoneReceiptId"])]
    checks += [("issuer", payload["services"]["issuerReceiptId"])] if path == "physical_id1" else [
        ("credential", payload["services"]["credentialReceiptId"])]
    for kind, identifier in checks:
        result = _assess_receipt(kind, identifier, server, expected_binding, front, back, payload, portrait)
        if result is not None:
            return result
    return None


def _assess_outcomes(payload):
    path = payload['credential']['path']
    outcomes = payload["outcomes"]
    if "fail" in outcomes.values():
        return "REJECT", "required_check_failed"
    if outcomes["face"] == "manual_review":
        return "REVIEW", "face_review_required"
    allowed = {"pass"} if path == "physical_id1" else {"pass", "not_performed"}
    if outcomes["face"] != "pass" or outcomes["document"] != "pass" or outcomes["physical"] not in allowed:
        return "INCOMPLETE", "required_check_unavailable"
    return "ELIGIBLE_IN_FIXTURE", "all_example_predicates_satisfied"


def assess_fixture(fixture, payload_validator, envelope_validator):
    """Exercise policy predicates using fabricated server records and proof results.

    The synthetic proof state is a test input, never a claim that this function
    performs cryptographic verification or is safe as a server endpoint.
    """
    if fixture.get("testOnly") is not True:
        raise ValueError("synthetic_fixture_required")
    envelope, server = fixture["envelope"], fixture["syntheticServer"]
    if len(json.dumps(envelope, ensure_ascii=False).encode("utf-8")) > 65536:
        raise ValueError("envelope_byte_limit")
    envelope_validator.validate(envelope)
    if len(envelope["payloadJson"].encode("utf-8")) > 32768:
        raise ValueError("payload_byte_limit")
    decode_canonical(envelope["challenge"], 32)
    decode_canonical(envelope["appAttestAssertion"]["assertionObject"])
    decode_canonical(envelope["appAttestAssertion"]["clientDataHash"], 32)
    payload = parse(envelope["payloadJson"])
    payload_validator.validate(payload)
    proof = envelope["appAttestAssertion"]
    if proof["clientDataHash"] != request_hash(envelope["challenge"], envelope["payloadJson"]):
        return "REFUSE", "request_hash_mismatch"
    if payload["session"] != server["session"]:
        return "REFUSE", "session_binding_mismatch"
    replay = _assess_replay(envelope, server)
    if replay is not None:
        return replay
    proof_result = _assess_proof(payload, envelope, server)
    if proof_result is not None:
        return proof_result
    for assess in (_assess_capture, _assess_receipts):
        result = assess(payload, server)
        if result is not None:
            return result
    return _assess_outcomes(payload)


def payload_change(fixture, transform):
    payload = parse(fixture["envelope"]["payloadJson"])
    transform(payload)
    text = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    fixture["envelope"]["payloadJson"] = text
    fixture["envelope"]["appAttestAssertion"]["clientDataHash"] = request_hash(fixture["envelope"]["challenge"], text)


def observed_outcome(fixture, **values):
    # A legitimate negative result changes both the report and its projection.
    fixture["syntheticServer"]["trustedEvidence"]["outcomes"].update(values)
    payload_change(fixture, lambda p: p["outcomes"].update(values))


def check_case(baseline, results, payload_validator, envelope_validator, name, mutate=None, expected="ELIGIBLE_IN_FIXTURE", reason=None):
    fixture = deepcopy(baseline)
    if mutate:
        mutate(fixture)
    try:
        actual, actual_reason = assess_fixture(fixture, payload_validator, envelope_validator)
    except Exception as error:
        actual, actual_reason = "INVALID", type(error).__name__
    assert actual == expected, (name, expected, actual, actual_reason)
    if reason:
        assert actual_reason == reason, (name, reason, actual_reason)
    results.append({"case": name, "outcome": actual, "reason": actual_reason})


def main():
    payload_validator, envelope_validator = schemas()
    baseline = parse((HERE / "fixtures" / "ios-id1-complete.example.json").read_text())
    assert baseline["payload"] == parse(baseline["envelope"]["payloadJson"])
    results = []

    check = partial(check_case, baseline, results, payload_validator, envelope_validator)


    check("synthetic_complete_signals")
    check("face_nonmatch", lambda f: observed_outcome(f, face="fail"), "REJECT")
    check("face_review", lambda f: observed_outcome(f, face="manual_review"), "REVIEW")
    check("physical_unavailable", lambda f: observed_outcome(f, physical="unavailable"), "INCOMPLETE")
    check("reported_outcome_disagrees_with_evidence", lambda f: payload_change(f, lambda p: p["outcomes"].update(face="fail")), "REFUSE")
    check("issuer_unavailable", lambda f: f["syntheticServer"]["receipts"]["example-issuer-receipt"].update(outcome="unavailable"), "INCOMPLETE")
    check("phone_contradiction", lambda f: f["syntheticServer"]["receipts"]["example-phone-receipt"].update(outcome="contradicted"), "REJECT")
    check("phone_not_compared", lambda f: f["syntheticServer"]["receipts"]["example-phone-receipt"].update(outcome="not_compared"), "INCOMPLETE")
    check("wrong_subject_binding", lambda f: f["syntheticServer"]["receipts"]["example-phone-receipt"]["binding"].update(subjectDigest="0"*64), "REFUSE")
    def inconsistent_receipts(fixture):
        for receipt in fixture["syntheticServer"]["receipts"].values():
            receipt["binding"]["generation"] = 8
    check("receipt_generation_differs_from_session", inconsistent_receipts, "REFUSE")
    check("unverified_receipt", lambda f: f["syntheticServer"]["receipts"]["example-issuer-receipt"].update(verified=False), "REFUSE")
    check("receipt_expired", lambda f: f["syntheticServer"]["receipts"]["example-phone-receipt"].update(expiresAt=1), "REFUSE")
    check("issuer_capture_substitution", lambda f: f["syntheticServer"]["receipts"]["example-issuer-receipt"]["front"].update(sha256="0"*64), "REFUSE")
    check("portrait_source_substitution", lambda f: payload_change(f, lambda p: p["capture"]["portrait"].update(sourceSha256="0"*64)), "REFUSE")
    check("front_back_alias", lambda f: payload_change(f, lambda p: p["capture"]["back"].update(captureId=p["capture"]["front"]["captureId"])), "REFUSE")
    check("unapproved_model", lambda f: payload_change(f, lambda p: p["artifacts"].update(modelManifestSha256="0"*64)), "REFUSE")
    for field in ("admissionReceiptSha256", "custodyRootSha256", "cadastralReportSha256"):
        check("substituted_"+field, lambda f, field=field: payload_change(f, lambda p: p["evidence"].update({field: "0"*64})), "REFUSE")
    for field in ("sha256", "derivationSha256"):
        check("substituted_portrait_"+field, lambda f, field=field: payload_change(f, lambda p: p["capture"]["portrait"].update({field: "0"*64})), "REFUSE")
    check("substituted_selfie", lambda f: payload_change(f, lambda p: p["capture"]["selfie"].update(sha256="0"*64)), "REFUSE")
    check("substituted_document_report", lambda f: payload_change(f, lambda p: p["credential"].update(reportSha256="0"*64)), "REFUSE")
    check("admission_not_live", lambda f: f["syntheticServer"]["trustedEvidence"]["admission"].update(assessment="flat"), "REFUSE")
    check("wrong_attempt", lambda f: payload_change(f, lambda p: p["session"].update(generation=2)), "REFUSE")
    check("replayed_challenge", lambda f: f["syntheticServer"].update(challengeConsumed=True), "REFUSE")
    check("expired_challenge", lambda f: f["syntheticServer"].update(challengeExpiresAt=1), "REFUSE")
    check("wrong_app_attest_environment", lambda f: f["syntheticServer"].update(proofEnvironment="development"), "REFUSE")
    check("proof_not_verified", lambda f: f["syntheticServer"].update(proofVerified=False), "REFUSE")
    check("counter_reordering", lambda f: f["syntheticServer"].update(assertionCounter=1), "RETRY")
    check("payload_bytes_changed", lambda f: f["envelope"].update(payloadJson=f["envelope"]["payloadJson"]+" "), "REFUSE")
    check("duplicate_json_key", lambda f: f["envelope"].update(payloadJson='{"schemaVersion":"a","schemaVersion":"b"}'), "INVALID")
    check("nonfinite_json_number", lambda f: f["envelope"].update(payloadJson='{"value":NaN}'), "INVALID")
    check("nonfinite_exponent", lambda f: f["envelope"].update(payloadJson='{"value":1e999}'), "INVALID")
    check("invalid_unicode", lambda f: f["envelope"].update(payloadJson='{"value":"\\ud800"}'), "INVALID")
    check("payload_byte_limit", lambda f: f["envelope"].update(payloadJson='{"value":"'+"é"*17000+'"}'), "INVALID")
    check("payload_depth_limit", lambda f: f["envelope"].update(payloadJson="["*20+"0"+"]"*20), "INVALID")
    check("unsafe_generation_integer", lambda f: payload_change(f, lambda p: p["session"].update(generation=9007199254740992)), "INVALID")
    check("extra_raw_biometric_field", lambda f: payload_change(f, lambda p: p.update(embedding=[0]*512)), "INVALID")
    check("missing_id1_back", lambda f: payload_change(f, lambda p: p["capture"].update(back=None)), "INVALID")
    check("noncanonical_challenge", lambda f: f["envelope"].update(challenge=f["envelope"]["challenge"][:-1]+"B"), "INVALID")
    check("missing_crypto_receipt", lambda f: payload_change(f, lambda p: p["credential"].update(path="icao9303")), "INVALID")
    def exact_replay(fixture):
        envelope = fixture["envelope"]
        server = fixture["syntheticServer"]
        server["challengeConsumed"] = True
        server["storedCounter"] = server["assertionCounter"]
        server["priorResult"] = {"envelopeDigest": hashlib.sha256(json.dumps(
            envelope, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "retainedUntil": server["now"]+1000}
    check("authenticated_identical_result_readback", exact_replay, "REPLAY_OF_FIXTURE_RESULT")
    def altered_replay(fixture):
        exact_replay(fixture)
        payload_change(fixture, lambda p: p["outcomes"].update(face="fail"))
    check("altered_consumed_request", altered_replay, "REFUSE")

    for path in ("icao9303", "mdl18013_5"):
        fixture = parse((HERE / "fixtures" / (path+".example.json")).read_text())
        assert fixture["payload"] == parse(fixture["envelope"]["payloadJson"])
        actual, reason = assess_fixture(fixture, payload_validator, envelope_validator)
        assert actual == "ELIGIBLE_IN_FIXTURE", (path, actual, reason)
        results.append({"case": path+"_synthetic_positive", "outcome": actual, "reason": reason})
        fixture["syntheticServer"]["trustedEvidence"]["admission"]["assessment"] = "flat"
        actual, reason = assess_fixture(fixture, payload_validator, envelope_validator)
        assert actual == "REFUSE", (path, actual, reason)
        results.append({"case": path+"_still_requires_live_selfie", "outcome": actual, "reason": reason})

    # Links and labels are part of the document deliverable, not accuracy tests.
    spec_path = HERE / "SPEC-IDBIO-200.md"
    spec = spec_path.read_text()
    missing = []
    for label in re.findall(r"\]\(([^\n]+?)\)", spec):
        if label.startswith(("https://", "http://", "#")):
            continue
        target = label.split("#", 1)[0].strip("<>")
        if target and not (HERE / target).exists():
            missing.append(target)
    assert not missing, missing
    report = {
        "scope": "Offline candidate schema and policy fixtures only; no cryptographic, empirical or production acceptance evidence",
        "specSHA256": hashlib.sha256(spec_path.read_bytes()).hexdigest(),
        "checkerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "schemaSHA256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted((HERE / "contracts").glob("*.json"))},
        "fixtureSHA256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted((HERE / "fixtures").glob("*.json"))},
        "cases": results,
        "localLinksResolve": True,
    }
    (HERE / "validation-results.json").write_text(json.dumps(report, indent=2)+"\n")
    print(f"PASS: {len(results)} candidate cases; both schemas; specification local links")


if __name__ == "__main__":
    main()
