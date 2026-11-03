# Signed capture manifest contract v1

This foundation module owns a canonical, immutable capture commitment and a signing port. It has
no product workflow, UI, network or provider dependency. `CapturePublicationContext` is required;
there is no mode that returns unsigned success. The native identity SDK's
`CaptureEvidenceManifestSigner` implements the port using its existing evidence receipt issuer,
hardware/software key reporting, serialized Merkle ledger and erasure fence.

The context carries application and installation identifiers, workflow UUID, local capture workflow epoch (separate from the server enrollment generation),
attempt UUID and device-asserted clocks. Manifest v1 binds the publication UUID/kind, exact retained
payload SHA-256, exact existing capability-manifest SHA-256, original/derived artifact references,
ordered derivation steps, model identities and mandatory policy identities. A source is not invented
for an unavailable original. Every derivative requires one preceding declared input; cycles and
unbound outputs are rejected. Hashes and lineage are commitments, not sensor truth or calibration.

Signing bytes are UTF-8 `kenshiki:capture-evidence-manifest:v1`, NUL, then the Swift sorted-key JSON
encoding with unescaped slashes, Foundation UUID spelling, integer clocks, omitted optional members
and array order preserved. Identifiers are bounded ASCII; digests are lowercase hexadecimal.
Schema validation runs after decoding and before signing or verification. New schema/proof versions
must be explicit; they cannot be interpreted as v1. Millisecond wall time is not server freshness.

`EvidenceManifestProof` contains adapter-versioned proof bytes and a key hash. The proof alone does
not establish trust. `SignedCaptureEvidenceManifest.verify` requires an externally trusted signing
key hash, expected publication context/UUID, exact payload and exact capability-manifest bytes.
The SDK adapter verifies the existing v2 receipt's signature, claim hash, key hash, leaf hash and
receipt conventions. It does not establish Apple attestation or authenticate a `secureHardware` claim
from the receipt itself. A server may trust this key only after independently registering/binding
it through its authenticated installation protocol.

## Adoption boundary

These primitives and the SDK adapter do not automatically sign historical capture records. Existing
CaptureEvidenceStore V1/V2 envelopes authenticate encrypted bytes but have no manifest signature.
They must not authorize a new signed-only read. A future `storeSigned`/`readSigned` integration must
publish the proof with the encrypted original atomically, preserve the capability manifest as-is,
and reject a missing/invalid proof instead of treating an old envelope as current evidence.

The concrete writer inventory includes original capture (`KenshikiCapture/CaptureDocumentStages`),
recording journal/writer, selfie retention, completed capture results, licence check archive,
portrait-model capture and face-comparison retention. Their workflow/generation/attempt context is
not interchangeable; each adapter must supply its actual context before publication. SSA/Pulse
composition owns installation/session selection; native SDKs own signing and protected persistence.

No current outgoing licence/home/face request automatically carries this new manifest digest. Such
adoption requires versioned request contracts, exact-byte fixtures and server binding to the current
installation/session/generation/operation/source before acceptance. Existing App Attest assertions
remain separate request proofs, and existing server Merkle checkpoints remain separate rollback
anchors. This module makes no deployment, installation or device-acceptance claim.
