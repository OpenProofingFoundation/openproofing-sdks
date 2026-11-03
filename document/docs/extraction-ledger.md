# Document SDK extraction ledger

## iOS document extraction, 2026-10-23

The reusable document implementation moves from `kenshiki-identity-sdk` to this capability.
The source is its post-Regula-removal working tree at revision
`0a1d0a0ec0fb7d3f435fb25608ca25e7b673bdbd`; exact file hashes, not the revision alone,
identify imported bytes. The destination starts at committed monorepo revision `4bf1e97`.
The primary preserved checkout and other in-progress worktrees are not replaced.

| Slice | Destination and boundary |
| --- | --- |
| AAMVA and document contracts | `ios/Sources/DocumentSDK`; no passport parser or product backend |
| Geometry, guided capture and processing | `DocumentCaptureApple`, including unchanged OpenCV algorithms and engineering defaults |
| Preview | Optional `DocumentCapturePreview`; host owns localized wording and presentation |
| Temporal recording | `DocumentCaptureJournal`; bounded queue/disk and clock/lifecycle behavior retained |
| Front/back workflow and derived artifacts | `DocumentCapture`; source hashes, signed-stage validation, portrait derivation and recovery |
| Custody | Shared `foundation/Sources/CaptureEvidenceCustody`; existing protected storage/evidence manifests reused |
| Workflow checkpoints | Document-owned typed selections over a foundation-owned opaque, encrypted revision/CAS mechanism |
| Native bridge | `native/DocumentOpenCVBridge`; source rebuilt and verified rather than copying stale donor binaries |
| Regression suites | Core, Apple, recording, workflow and custody tests move with implementation; private replay stays explicit and external |
| Independent consumer | `examples/ios`; UIKit public-API optical sample without a backend or injected synthetic production signer |

`../Gates/capture-sources.json` retains each Swift donor path/digest, current destination
digest and adaptation record. `../Gates/native-sources.json` records the native sources;
`foundation/capture-custody-extraction.json` records shared custody. Donor source/test hashes
are compared again at final validation. Third-party notices remain with the corresponding
implementation. The frozen SPEC-IDBIO-200 hash is recorded, and APP-ARCH-001 revision 0.2
owns the current document/passport/shared-foundation placement.

Adaptations are explicit: module boundaries; host-supplied environment/notification inputs;
neutral operational API names with retained wire keys; stable profile codes with legacy
metadata decoding; schema-4 native extraction without embedded passport parsing; and an opaque
shared checkpoint mechanism preserving historical file names and authenticated-data bindings.
These changes do not add an authenticity pass, face-match threshold or complete identity claim.

## Validation and remaining adoption

Run root governance/guards, public API snapshots, macOS, both iOS build lanes, the required
no-skip iOS behavior suite and the existing Android contract lane. Shared foundation changes
also execute its root and nested consumers. The native runner records source/dependency and
artifact hashes before/after execution, required exact test identities and crash evidence.
The independent sample compiles separately against the public products.

Physical camera behavior, accessibility, private-corpus replay, Android acquisition, paid
verification, reference-app flow wiring, and Pulse/SSA adoption remain separate qualification
or integration steps. Existing apps and the donor compatibility implementation remain intact
until reviewed SDK artifact/dependency cutovers. Future reusable document changes belong here;
this extraction does not authorize a second independently evolving implementation.

When adopting retained journal manifests whose entries omit an explicit side, the host's
`verify(profileSides:)` map must include historical profile aliases as well as current
stable codes. Profile decoding does not rewrite the original signed manifest or its bytes.

## Reusable front capture surface, 2026-10-25

The optional `DocumentCapturePreview` product adds a native front-camera surface with
host-prepared localized content, design tokens, action availability and advisory level state.
The layout draws on the existing SSA front guidance and Pulse viewport; the level projection
preserves their gravity/freshness behavior. The new UIKit renderers only apply supplied state
and emit capture/cancel intents. Motion delivery and automatic acquisition remain in the
document Apple capability, composed from its existing collector, camera and auto-capture
mechanisms. No renderer owns a sensor, clock, capture policy or product service.

New source records retain the original SSA/Pulse paths, ancestry revisions and exact donor
hashes in `sourceReferences`; dirty donor bytes are identified by their hashes rather than
misrepresented as committed bytes. A null primary donor marks a new composition or native
adaptation, not a literal imported source file. Original extraction donor hashes remain intact.
The presentation guard now discovers the entire optional preview source tree, distinguishes
the existing platform preview/geometry adapter from pure front UI, and rejects unregistered
sources, role changes and behavior hidden in rendering helpers or action closures.

This slice adds no provider integration, issuing-state check, durable store or Pulse/SSA
dependency cutover. Source checks, compiler-derived additive public API review, native tests,
reference-app integration, accessibility and physical acceptance remain separate evidence.
