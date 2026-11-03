# Optional Pulse passport service

`KenshikiPulsePassport` is an optional product of the repository-root Swift package.
It owns the Pulse passport HTTP contract, preparation lifecycle and installation
credential mutation sequencing. Both the reference app and Pulse consume this
implementation. Neutral passport, document, biometric, presentation and foundation
products do not depend on it.

The product depends only on `KenshikiOperationBinding` and native system frameworks.
It has no dependency on either app, the predecessor identity SDK, NFC capture, UI,
face models or a calibrated identity threshold. It reuses foundation's canonical
serialization, key custody, attestation signing and protected storage mechanisms.
The independent headless passport SDK does not require a Pulse account or backend.

## Ownership and ordering

`PulsePassportService` owns the complete preparation attempt, including the stable
operation identifier and timestamp, a cached live session/nonce, classified bounded
recovery and generation fencing. Cancellation during positioning retains a usable
challenge. Verification dispatch retires it because a lost response can still mean
the server consumed the nonce. An explicit restart clears the previous attempt.
Every delivered read retires its exact challenge, including local admission or
conversion refusal and cancellation after delivery. `discardDeliveredRead` handles
only those refusals; a stale callback cannot retire a newer preparation. Coalesced
callers receive the current preparation stage and subsequent stages independently.

The host invokes its NFC reader with the prepared challenge. Before any final
verification request, the shared service invokes the host's local admission check:
authenticated credential integrity, reviewed printed-page/chip correspondence and
original portrait lineage remain prerequisites. A refusal does not submit that read
to `/passport/verify`. The server remains authoritative for the recorded ICAO
validation and its actual assurance scope.

The shared registration owner sequences credential mutations. Existing Pulse custody
is bridged through its existing credential and key slots, preserving installation
identity and downstream holder linkage. Bearer recovery retains the registered key.
Only the exact platform `invalidKey` condition permits automatic dead-key replacement;
a transport failure or ordinary server refusal does not rotate it. The reference
registers its own installation and uses its bundle identifier for Worker recovery.
Direct Pulse continuity clients and their copies retain that same owner. Mutations
hold the host's existing erasure lease across awaited work. Erasure closes admission,
cancels and drains prior mutations and invalidates old clients before deleting keys
and credentials. Installation deletion uses the host's existing server authority and
compares the exact retained identity before local removal; failure retains custody.
The successful final-erasure callback runs inside that exclusive boundary, before
new enrollment is admitted. Hosts publish persisted identity changes from the
serialized storage adapter, rather than from callers resuming after a mutation.

The default transport uses an ephemeral session, refuses redirects and bounds
responses while streaming. Explicit predecessor transport injection remains supported;
its materialized-response interface can enforce URL and byte limits only after the
injected transport returns. Callers supplying that transport retain its egress policy.

Acceptance carries the exact server check report and a private holder capability
bound to the SOD, installation and service origin. Its explicit protected storage
representation belongs only in encrypted custody. It must not enter report exports,
display rows or diagnostics. A new read clears a previous capability. Shared check
projection preserves unknown historical fields and omits unperformed optional AA/CA.
Hosts supply localized wording and render prepared rows.
Failed server verdicts retain their actual checks without an accepted capability;
transport and local admission errors do not manufacture a server report.
An existing Bond-issued nonce can use `verifyIssuedRead` without creating another
session or nonce. It retains its actual workflow and payload commitment and produces
the same accepted-read/report/capability pair. Current installation and origin must
match before private holder use; historical public verification remains a dated fact.

This extraction does not add remote face/vouch writes. The reference continues its
selected local AuraFace cosine observation without inventing a match threshold.
Pulse's separate holder and face workflows retain their existing contracts.

## Qualification

The source inventory, dependency direction and public-surface gate are enforced by
`quality/pulse_guards.py`. The real root workflow executes all three lanes:

```sh
bash scripts/python.sh scripts/pulse_check.py --platform macos
bash scripts/python.sh scripts/pulse_check.py --platform ios-device
bash scripts/python.sh scripts/pulse_check.py --platform ios-simulator
```

The simulator lane requires every declared service test ID to pass without skips,
expected failures or stale results. Compiler-derived API snapshots are reviewed for
each platform. Receipts bind source inputs, command, current revision, logs and API
artifacts; changing source during execution invalidates qualification. Initial API
authoring uses an explicit `--write-api` option that CI never supplies.
The [test continuation map](test-migration.json) records all 47 original Pulse
preparation, classification, state and client-hash tests against pinned donor source.
Native adopter obligations remain separate from execution in the shared service job.

Reader runtime repair is checked separately, including explicit byte comparison with
the actual dependency used by Pulse:

```sh
bash scripts/python.sh quality/reader_parity.py --identity-sdk /path/to/kenshiki-identity-sdk
```

No automated receipt establishes real App Attest, CoreNFC, installed-artifact or
physical Passport → Selfie → Result acceptance. Those require separate evidence on
the exact signed build. See the governing adoption plan in
[APP-ARCH-001 A.17](../../governance/architecture/APP-ARCH-001.md#a17-complete-pulse-passport-adoption-and-shared-repair-23-october-2026)
and the current [handoff](../../HANDOFF.md).
