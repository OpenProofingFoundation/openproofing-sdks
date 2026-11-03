"""Reproduce narrow draft checks; does not evaluate biometric or attack accuracy.

Monorepo patch 2026-10-16: extract schema-example construction without changing
the frozen draft, schema interpretation, arithmetic or source-review semantics.
"""
import hashlib
import json
import math
from pathlib import Path
import re

import numpy as np
from jsonschema import Draft7Validator, FormatChecker


def example(node):
    if "const" in node:
        return node["const"]
    if "enum" in node:
        return node["enum"][0]
    kind = node["type"]
    if kind == "object":
        return {k: example(node["properties"][k]) for k in node.get("required", [])}
    if kind == "array":
        return [example(node["items"]) for _ in range(node.get("minItems", 0))]
    if kind in ("integer", "number"):
        return node.get("minimum", 0)
    if kind == "boolean":
        return False
    if node.get("format") == "uuid":
        return "00000000-0000-4000-8000-000000000001"
    pattern = node.get("pattern", "")
    if "a-f0-9" in pattern:
        return "a" * 64
    if "A-Z0-9" in pattern:
        return "636045"
    return "A" * 64


def run():
    folder = Path(__file__).resolve().parent
    spec = folder / "history" / "SPEC-IDBIO-200-v3.0.md"
    raw = spec.read_bytes()
    text = raw.decode()
    section = text.split("## **A.2", 1)[1].split("## **A.3", 1)[0]
    schema_text = section[section.index("{"):].strip()
    # Remove only Markdown punctuation escapes, preserving JSON string escapes.
    schema = json.loads(re.sub(r"\\([\\`*_{}\[\]()#+\-.!<>|=$])", r"\1", schema_text))


    candidate = example(schema)
    candidate["physicsGate"]["telemetryBitmask"] = 0x03FF
    candidate["biometricVerification"]["decision"] = "NON_MATCH"
    candidate["documentVerification"]["cryptographicSignatureValid"] = False
    errors = list(Draft7Validator(schema, format_checker=FormatChecker()).iter_errors(candidate))

    # Two points on the same camera ray, at different depths, under pure rotation.
    # This demonstrates depth independence, not a working PAD algorithm.
    angle = 0.01
    rotation = np.array([[math.cos(angle), 0, math.sin(angle)], [0, 1, 0],
                         [-math.sin(angle), 0, math.cos(angle)]])
    rays = np.array([[0.2, 0.1, 1.0], [2.0, 1.0, 10.0]])
    rotated = rays @ rotation.T
    normalized = rotated[:, :2] / rotated[:, 2:]
    depth_difference = float(np.max(np.abs(normalized[0] - normalized[1])))
    assert depth_difference < 1e-12
    assert not errors, [e.message for e in errors]

    root = folder.parents[1]
    paths = [
        "Sources/IdentityEvidenceApple/DocumentJourneyPacing.swift",
        "Sources/IdentityEvidenceApple/DocumentJourneyRecordingFrames.swift",
        "Sources/IdentityEvidenceApple/DocumentPerspectiveMeasurement.swift",
        "Sources/IdentityEvidenceApple/DocumentTiltController.swift",
        "Sources/IdentityEvidenceApple/AVFoundationTemporalCapture.swift",
        "Sources/IdentityEvidenceApple/DocumentTemporalMotionCollector.swift",
        "Sources/CaptureSelfie/SelfieDepthPolicy.swift",
        "Sources/KenshikiIdentity/AppleAppAttestProvider.swift",
        "Sources/KenshikiIdentity/EvidenceIntegrityIssuer.swift",
        "Tools/Cadastral/prepare.py",
        "Tools/CardRectification/rectify.py",
        "Tools/CardTopology/audit.py",
        "Tools/RegionSegmentation/experiment.py",
        "Tools/RegionSegmentation/adjacency.py",
        "Tools/AppleMaterials/metrics.py",
        "Tools/TemporalEvidence/analyze.py",
        "Tools/TemporalEvidence/measure.py",
        "Tools/TemporalEvidence/review.py",
        "Packages/IdentityGateway/Sources/IdentityGateway/PulsePersonaBarcode.swift",
        "Packages/IdentityGateway/Sources/IdentityGateway/PulseFaceAttestClient.swift",
        "Packages/IdentityEvidenceFaceMatching/Sources/IdentityEvidenceFaceMatching/FaceComparisonSubmissionEvidence.swift",
        "Packages/IdentityEvidencePassport/Sources/IdentityEvidencePassport/PassportObservationMapper.swift",
        "ThirdParty/FaceMatching/Provenance/pulse-face-embedder-provenance.md",
        "../pulse-worker/src/ssaSmsRoutes.ts",
        "../pulse-worker/src/enrollmentPhoneGate.ts",
        "../pulse-worker/src/nativeFaceAttestRoutes.ts",
        "../camara-api/src/routers/identity.py",
    ]
    return {
        "scope": "Draft arithmetic, schema example and projective counterexample; no accuracy or device validation",
        "draftSHA256": hashlib.sha256(raw).hexdigest(),
        "schema": {
            "markdownEscapeRemovalRequired": True,
            "declaredDialect": schema["$schema"],
            "explicitDraft7NonMatchFullMaskExampleValid": not errors,
            "meaning": "Structural validity plus full mask is insufficient as an acceptance policy",
            "signatureRequiredInsidePayload": "enclaveSignature" in schema["required"],
        },
        "pureRotation": {"differentDepthSameRayProjectionMaximumDifference": depth_difference},
        "arithmetic": {
            "twoFramesAt30FPSMilliseconds": 2000 / 30,
            "framesIn400msAt30FPS": 30 * .4,
            "cyclesIn400msAt8And12Hz": [8 * .4, 12 * .4],
            "centroidFP32Bytes": 150 * 512 * 4,
            "listedModelSubtotalMB": [sum([.8, .6, 2.1, 3.2, 4.1, 4.5]),
                                       sum([.8, .6, 2.1, 3.2, 4.1, 22])],
            "rasterVerticalPixelsPerNominalMillimeter": 540 / 53.98,
        },
        "sourceSHA256": {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in paths},
    }


if __name__ == "__main__":
    print(json.dumps(run(), indent=2, allow_nan=False))
