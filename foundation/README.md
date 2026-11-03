# Shared native foundation

[Kenshiki Sensors](sensors/README.md) extracts Pulse's existing clock, window,
statistical and motion-reducer core into an independent local Swift package.
Its [measurement/window contract](../contracts/sensor-measurement-window-v1.md)
and common vectors define explicit units, frames, timing, raw/aggregate retention,
absence and derived-result provenance. Existing `KenshikiMotion` remains compatible;
capture-workflow migration and physical qualification are separate work.

The independently consumable [Kenshiki Motion package and API guide](motion/README.md)
documents shared device-motion collection, permission handling, bounded raw windows
and derived features. It traces existing passport-to-selfie workflow recording,
selfie frame bindings and the separate document recorder. The guide distinguishes
exported SDK APIs from internal app composition and records gaps in schema/collector
unification and cross-sensor liveness inference.

`RegisteredKeyEnrollmentCustody` optionally supports a version-2, owned initial-attestation journal. A product adapter supplies bounded opaque challenge context, a strict known-transient classifier, validation and an explicit retry admission policy. Custody freezes that exact input before the platform call and persists a retryable phase only after a known transient result. Ambiguous interruption remains distinct. When a challenge expires after a known transient result, the same key is attested with a new challenge, because that key is provably unattested. After an ambiguous interruption or a late platform success, expiry is final. It never schedules retry, rotates a key or interprets product identity claims. Version-1 in-flight records remain nonresumable; prepared/registered recovery remains compatible. Cancellation, expiry, cooldown, malformed context, owner binding and missing-policy rollback have deterministic regression coverage. Platform and live-service acceptance require separate evidence.

`KenshikiOperationBinding` is an independently consumable Swift package implementing the versioned sealed-operation envelope, domain-separated SHA-256, exact content binding, registered-key assertion serialization, and request/result receipt comparison. Its platform dependencies include Foundation, CryptoKit, DeviceCheck, Security and the shared protected SQLCipher store; capability SDKs and UI remain outside its dependency graph. `sources.json` inventories every source and test. `python3 foundation/scripts/check.py` validates both manifests and inventory/dependencies, then runs the behavior suite through the root distribution manifest. `--nested` exercises the retained standalone manifest against the same source and test directories.


## Protected storage and key custody

Select `KenshikiProtectedStorage` independently of operation binding. It uses the official SQLCipher
4.19.0 dynamic XCFramework, pinned to supplier revision `39f212458aeb88e33bdac2200a793a3f0d55d32b`.
The supplier's SwiftPM manifest pins the binary SHA-256
`39f02d2f04f0de2ba1facf215550bfc6e6e2c9971d5d8ebb0cdd604874781bd7`.
[Required supplier attribution](SQLCIPHER-LICENSE.md) must accompany distributions embedding it.
This dependency is not an assertion of independent cryptographic certification.

`ProtectedSQLiteStore` requires a dedicated database-family directory and a fixed `StoreKeyIdentity`
(application, store, purpose, explicit app-private Keychain access group, access profile). Foreground identity uses iOS complete protection and
WhenUnlockedThisDeviceOnly Keychain custody; background collection uses complete-until-first-unlock
protection and AfterFirstUnlockThisDeviceOnly custody. Directory protection precedes database creation;
existing/recreated WAL, SHM, rollback journal and lifecycle files are included. SQLite temporary data
stays in memory; WAL commits use FULL synchronization and secure deletion. SQLCipher authenticates
and encrypts pages, including WAL and rollback-journal page contents. SHM/lifecycle metadata relies
on file protection and is not described as encrypted SQLCipher page data.

Every synchronous `withConnection` admission freshly unwraps its random 256-bit key through Secure
Enclave P-256 ECDH, HKDF-SHA256 and AES-GCM; then opens SQLCipher and closes its connection/page cache
on return or throw. Keys necessarily exist in RAM during use. Ordinary borrows retain no keyed connection between
admissions. No software fallback is available in production; hardware unavailable, Keychain locked,
missing key, wrong namespace and authenticated-page corruption are explicit failures. A retained store
never triggers unrelated replacement-key creation. The internal test adapters do not establish physical
hardware backing. Database, record-AEAD and evidence-signing identities must use distinct purposes.

`makeReadLease` is a separate, explicit background-only operation lasting at most 120 monotonic
seconds of `ContinuousClock`, including system sleep. Its query-only read transaction holds a stable WAL snapshot across pages. Each page freshly
checks the hardware key, its binding to the original lease, and the durable epoch before touching
cached pages. Deadline checks also refuse late callback results; a cancellable task closes idle
connections at expiry when the process can execute. The SPI refuses writes, transaction changes,
leaked statements and nested admissions. Foreground identity artifacts cannot acquire such a lease.
An eraser durably marks its generation pending, then refuses deletion with BUSY while an independent
lease holds its shared lock. That lease's next page refuses and closes; explicit erase retry completes.
Cancel, expiry, error and destruction release the read transaction. The `.lease-lock` inode remains in
the protected metadata inventory so concurrent waiters cannot split the lock namespace. These are
bounded background caches, not a claim that cached keys are absent throughout a live snapshot.

The SQL handle SPI is for reviewed storage adapters only: all SQL on its handle must import SQLCipher,
remain inside the callback and finalize statements before returning. Handles/statements cannot escape.
SQLCipher and system SQLite use different dynamically linked engines; mixing their functions on one
handle is invalid. Ordinary callbacks cannot disable encryption, move temporary data to disk, export or
attach plaintext, weaken durable journaling, or modify the foundation's reserved metadata. This is not a
sandbox against compromised host code in the same process; adopter guards enforce the SPI boundary.

Legacy plaintext migration is explicit. An attached read-only source includes retained WAL, while
`sqlcipher_export` writes a separate encrypted stage. Source commitments must remain unchanged across
export; schema checks, page authentication, user version, synchronized staging and atomic rename precede
publication. `finishLegacyCutover()` is called during exclusive adopter startup after all old accessors
are retired. It refuses active writers and changed sources, durably records a cleanup plan inside the
encrypted destination, then removes only those exact source files. Interrupted cleanup resumes without
re-exporting or deleting a replacement source. The source remains in the erase inventory until this
explicit cutover completes. An error never quarantines or recreates the canonical database.

`erase()` advances a durable generation under a cross-process advisory lock before deleting the full
ciphertext family and staging data, synchronizes file deletion, then removes the key. Independent old
handles cannot publish or erase a later generation. Interrupted erasure remains pending until explicit
retry or `resumePendingErasure`; opening is refused meanwhile. Lifecycle generations/locks remain as
identifying local metadata. They provide concurrency/restart fencing, not cryptographic anti-rollback
against restoration of the whole filesystem. Server-bound checkpoints must supply that separate claim.
Logical deletion and cryptographic key deletion do not prove forensic erasure of flash snapshots.

`recoverPendingErasure` is the startup variant: it returns false without deleting
anything when no erase intent exists, and completes only a previously durable
intent when one does. It also handles interruption after the database was removed
but before key removal. It creates no database or data key; malformed lifecycle
metadata remains an error. The original strict `resumePendingErasure` still refuses
calls without a pending intent.

Source tests, iOS compilation, simulator file-policy execution, physical locked-device behavior and
adopter migration/erasure acceptance are separate evidence gates. `OperationJournal` uses this store
for every complete synchronous operation; its production initializer requires an explicit identity
and an optional, separately named legacy plaintext source. Tests select synthetic SQLCipher fixtures
explicitly. The simulator cannot qualify physical Data Protection classes or Secure Enclave custody.

The wire source is `../contracts/sealed-operation-v1.schema.json`; shared conformance bytes are `../contracts/sealed-operation-v1.vectors.json` and `../contracts/operation-response-v1.vectors.json`. Product adapters supply closed canonical content, server-issued challenges, registered identities, authoritative media references and independently established evidence provenance. A valid device assertion does not establish government verification. Receipt digests bind complete requests and results, but require authenticated service transport.

`ServiceTrustPolicy` and `PinnedServiceHTTPTransport` require system-valid HTTPS chains plus configured service-controlled leaf SPKI SHA-256 pins, with at least two distinct keys for rotation. Unlisted hosts, redirects, malformed keys and unavailable configuration fail closed. The host must independently provision approved current/rotation pins. No production pins, installed configuration, deployment or device acceptance are claimed by these sources or synthetic tests.

`OperationJournal` durably records owner intent, exact prepared request bytes, uncertain dispatch and accepted results in a synchronous SQLite transaction ledger. Changed intent invalidates older handles across processes/restarts; an erase-generation fence prevents suspended old handles from publishing after local erasure. Only current revocations may obtain a new operation identity following an authoritative revision conflict; an older enable is never rebased. Adapters must record cancellation synchronously, validate intent after asynchronous preparation, recover uncertain outcomes through read-only service routes, and install a server revocation fence for requests already in flight.

The journal uses SQLCipher through `ProtectedSQLiteStore`, with WAL, synchronous FULL, secure deletion, backup exclusion and the identity's fixed iOS file/key access profile. No keyed connection survives an operation. Erasure deletes payloads, proofs and results, checkpoints the WAL, and retains application namespace/generation and admission fences. Those identifiers and counters are retained metadata; they are not described as anonymous. Host erasure inventories must include the database and its sidecars; the Pulse scheduled-share and shared operation stores register this obligation. Capacity and unreadable/corrupt stores fail closed rather than discarding consent history. Key custody, broader adopter migration and Android implementations remain separate work. Source, local tests, app compilation, installation and physical acceptance are distinct evidence.

`RevocationRecoveryController` adds two-phase erasure: first obtain and persist a validated service authorization while ordinary credentials remain available, then execute/recover the exact authorized request through a narrow deletion-only capability. The journal stores capability material and authorization separately from completion. D1 completion with external cleanup pending is never global erasure completion. Per-resource sessions and atomic retirement preserve unrelated pending delegations. Explicit owner admission grants persist against the exact current revocation identities and custody generation; a new deletion closes admission again. Local erasure retains and inventories pending capability material, and cannot report total completion while it remains. The application must bound capability retention, remove expired executable material and represent an unavailable outcome honestly.

`JournaledOperationController` centralizes frozen preparation, explicit execution, read-only recovery and current-intent projection. A cached accepted result still validates identity, exact request and result binding, while its previously authenticated receipt does not acquire a new execution lifetime. Recovery returning no receipt never dispatches through the read-only API. Schema 6 maintains a separate durable admission epoch: closing custody invalidates suspended preparation callers without destroying exact prepared operations needed by a fresh admitted recovery caller. Whole-file close/erase covers namespaces opened later as well as current handles.

Binary adapters may retain at most 1 MiB of exact recovery bytes in the same protected journal; the Pulse JPEG adapter enforces 600,000 bytes. An opt-in immutable payload deadline bounds raw-byte retention independently of request/result metadata; maintenance across all namespaces redacts expired bytes without reporting an unknown operation as completed. The Pulse adopter uses 24 hours and invokes maintenance during admission/reconciliation. Retries cannot reset the deadline or restore redacted bytes. Installation deletion delegation uses its separate 30-day policy and does not opt in to the binary deadline. Accepted binary payloads can be released with a checkpoint while the frozen request and result remain for binding. The host must retire cached publication projections when consent ends and authenticate current consent before treating a cached publication as active. No image re-encoding or sidecar blob store is implied.

`ExpiredUncommittedRefusal` binds a closed service refusal to the original operation, request digest and strict post-expiry decision time. `renewProtectiveAfterExpiredUncommitted` atomically replaces only the current nonterminal revoking attempt with unchanged content after validating the evidence, admission epoch and generation. It refuses accepted results, authorization/delegation material and stale handles. The Pulse Gateway restricts this mechanism to its four ordinary stop/delete kinds, obtains the refusal through authenticated service transport, and permits at most one renewal per invocation. Missing receipts, local time, generic errors and an expired proof alone never authorize renewal. Installation-erasure delegation is unchanged. `../contracts/protective-expiry-refusal-v1.vectors.json` is copied byte-for-byte from the actual Worker handler conformance fixture. Raw URL retention in saved results remains separate, unresolved work.

Schema 7 adds ordinary recovery-material retention. The first admission records a 30-day deadline, canonical content digest and optional explicit host business approval ID. Retrying, accepting and renewing an operation do not reset this deadline. Maintenance physically clears application-visible content/request/result/recovery columns while retaining distinct accepted, revoked or uncertain outcome facts, target/operation identifiers, digest and generation fences. These retained identifiers/digests remain identifying metadata. A retired association cannot prepare, dispatch or accept a late result, nor can repeated identical content allocate another generated operation; a genuinely new host-authorized business approval must supply a different stable approval ID. Gateway exposes only a target-bound, product-allowlisted protective reconstruction path; photo reconstruction remains unavailable without its media authority lookup.

Legacy prepared rows use the original structurally valid, row-bound operation expiry plus 30 days as a conservative retention bound, not as new evidence that a signature was verified. Ordinary legacy rows without that timestamp retire immediately. Namespace policy is persisted individually. Unknown legacy namespaces remain explicitly pending until their typed owner registers a policy; an unrelated opener never guesses whether they are delegated. Typed whole-file owners may supply an explicit legacy policy only for their owned file, without overriding persisted classifications. The installation deletion adapter explicitly selects delegated custody in its separate file and retains its existing capability lifecycle.

Logical scrubbing precedes the WAL checkpoint. A busy checkpoint reports failure and a durable pending marker causes restart to retry it. SQLite secure deletion, checkpoint completion and app-visible file scans do not establish forensic erasure of flash storage or filesystem snapshots. Parent operation payloads, history files, active Wallet serial capabilities and previously exported artifacts require their own typed retention integration; clearing the shared ledger alone does not clear these independent copies.

Git consumers select `KenshikiOperationBinding` from `https://github.com/Kenshiki-Labs/kenshiki-sdks.git` at an explicitly reviewed full commit revision; the SwiftPM dependency identity is `kenshiki-sdks`. The root manifest exports the operation binding, protected storage and evidence manifest products and points directly at their source/test directories. It introduces no capability dependency or source copy. The foundation SwiftPM root, iOS device compile and iOS simulator test jobs execute the distributed manifest. Actual App Attest, service configuration, device acceptance and adopter release evidence remain separate.


## Capture custody

`CaptureEvidenceCustody` reuses the foundation's protected storage and evidence manifest
mechanisms. It stores encrypted immutable artifacts and opaque revisioned checkpoint bytes.
The document capability owns typed front/back selections and their validity; foundation
binds each checkpoint to its workflow, revision, key, and historical authenticated-data domain.
Hosts supply application and key namespaces, access groups, storage roots, and signing adapters.
Synthetic signing and key fixtures are explicit debug-only SPI, absent from Release.

Capture owners call public `CaptureCustodyRuntime.prepareErasure()` before awaiting
native settlement. It permanently revokes admission and synchronizes the erase
intent while retaining ciphertext; later `erase()` drains publication, removes
records and keys, and completes the intent. Failed settlement cannot reopen this
generation, and an interrupted preparation remains explicit erase-only recovery.


`SecureEnclaveCaptureManifestSigner` is an opt-in local `EvidenceManifestSigning` adapter.
Its explicit `StoreKeyIdentity` must use foreground identity protection and a separate signing
purpose. The retained opaque Secure Enclave P-256 signing key uses a fixed signing-specific
Keychain service/account domain, distinct from database ECDH keys even if an adopter reuses an
identity. `prepareSigningPublicKeyHash()` explicitly provisions a first key; historical lookup,
signing and verification never provision. An adopter with retained evidence must first resolve
`existingSigningPublicKeyHash()` and compare its independently retained anchor, refusing missing
or changed keys rather than preparing a replacement. Verification binds the exact manifest bytes
to that retained key; proofs do not carry an authoritative replacement key. Hardware unavailable,
locked, corrupt or missing custody fails explicitly, without production software fallback. This is
local evidence integrity, not App Attest, sensor authenticity, government verification or a server
identity claim. `eraseKeyAfterCiphertextErasure()` permanently retires that signer instance and
must only follow deletion of the ciphertext it signs.

Reviewed SQL adapters that also own an associated signing key use the `StorageAdapter` SPI's
`ProtectedSQLiteStore.prepareErasure()` and returned `ProtectedSQLiteErasure.finish()`. Preparation
persists the existing erase intent, removes the ciphertext family and data key, and leaves the
intent pending while the adopter awaits signing-key cleanup. Only after cleanup succeeds does it
finish that pending generation. Failure or interruption leaves ordinary opening refused; explicit
delete retry uses static `prepareErasure(databaseURL:identity:)` to resume the same intent before
retrying associated cleanup. `hasPendingErasure(databaseURL:identity:)` observes intent without
creating directories, databases or keys, and must precede an adopter's missing-database return.
Bound preparation and completion refuse replacement generations. These adopters must consistently
use this coordinated path rather than the older single-resource recovery methods, which cannot
know whether an associated signing key was deleted. The SPI adds no separate lifecycle record,
SQL schema, remote enrollment or public SQL engine. Synthetic SQLCipher tests and native compilation
do not qualify physical Secure Enclave custody or locked-device behavior.
