# Passport SDK extraction ledger

The owner selected independently consumable document, passport and biometric products in the `kenshiki-sdks` monorepo. The iOS MRZ/NFC source port is now present: neutral `PassportSDK`, optional `PassportNFC`, `PassportMRZCapture` and `PassportMRZPreview`, and the complete patched supplier reader. [Source provenance](../Gates/extraction-sources.json) identifies original donor bytes and explicit destination patches. Native execution, host integration and physical acceptance are recorded separately; Android remains the outcome scaffold.

| Slice | Existing source / authority | Next work | Status |
| --- | --- | --- | --- |
| Package/QA boundary | Document capability scaffold QA framework | Independent Swift/Android products, six outcomes, four compiler-derived API snapshots | Scaffold; dated evidence in port-validation.json and fresh runner receipts |
| MRZ capture/parse | Identity SDK Packages/IdentityEvidencePassport/Sources/CaptureMRZ and PassportMRZOCRParser.swift | Native execution and physical capture acceptance; preserve synthetic corpus | iOS source port present; behavior/build receipts separate |
| NFC reader/access | Identity SDK passport adapter and ThirdParty/NFCPassportReader | Execute protocol/recovery suites and physically qualify destination package | Complete iOS source port present, including attributed security corrections |
| Credential authentication | PassportReadObservation.swift, PassportObservationMapper.swift; SPEC-IDBIO-200 §6.2 | Validate preserved PA/AA/CA outcomes and negative paths; expand algorithm identity separately | Existing iOS wrapper/verification port present; algorithm limitations below |
| Trust and portrait | Existing passport trust/custody adapters; SPEC-IDBIO-200 §6.2 | Native portrait handoff; versioned trust acquisition/update and shared custody remain next | Host-supplied PEM and DG2-bound original portrait port present; custody unported |
| Shared foundation and native UI | APP-ARCH-001 rev0.1 | Adopt common storage/keys/proof/lifecycle and pure native presentation with JSONC/i18n/A11y | Planned |
| Integration | Public passport and biometric contracts | Bound credential/portrait/selfie/server receipts and installed native/device acceptance | Planned |

Before moving a source file, record its revision, working-tree hash, dependencies, ownership/licence and destination. Preserve unrelated source edits and all original byte contracts. Move behavior/negative fixtures, parser fuzz/sanitizer, protocol, trust, key/custody and physical recovery tests with each implementation slice. Source, compilation, automated execution, installation and physical NFC/assistive-technology acceptance are separate evidence.

## Owner-authorized NFC clean port — 17 October 2026

The implementation sequence and acceptance gates are in [APP-ARCH-001 Appendix A.6](../../governance/architecture/APP-ARCH-001.md#a6-passport-maintenance-and-adopter-migration). The table above records destination source state; the inventory below separates donor behavior from destination execution. A source port is not physical acceptance, a Pulse migration, or an Android implementation.

### Source audit and preserved investment

The audit located the identity checkout at `ef55248549cb83bb554d67e5e2d4068a0c3ca70f` and Pulse at `eead3323fb4cd1712de7fd2d82b9fdf55555026e`. Imported-file working-tree hashes and dirty status must be captured by the extraction manifest; revision identity alone is insufficient for dirty donors. These are located revisions, not declarations that all source files equal those commits.

| Existing component | Source and role | Destination scope / status |
| --- | --- | --- |
| MRZ/access and NFC wrapper | `kenshiki-identity-sdk/Packages/IdentityEvidencePassport`: TD3 OCR repair/check digits, access key, printed/chip correspondence, typed reader events/failures, post-transport verification and original portrait | Authorized for standalone port with its negative/lifecycle tests; implementation and native receipts must be recorded below as they land |
| Actual shared NFC implementation | `kenshiki-identity-sdk/ThirdParty/NFCPassportReader`: AndyQ 2.3.1 plus recorded Pulse and identity patches | Preserve complete tree, MIT attribution, privacy resource, package/OpenSSL identity and all local recovery/crypto patches; inspect destination manifest rather than importing a fresh upstream release |
| Authentication harness | Identity `Tests/PACETransportTests` and `scripts/assurance/pace-harness`: production APDU/PACE/BAC exercised using synthetic peers | Must execute against the copied destination sources; parser/lifecycle/wrapper tests alone do not replace it |
| Pulse host read | `PassportChipRead.swift`: host PEM selection and localized sheet messages; nonce-derived AA challenge; remote CA relay; transport-only motion window; original portrait and display-JPEG separation | Preserve host behavior during later adopter migration; do not pull bundle lookup, product motion witnesses or Worker clients into neutral reader |
| Pulse server composition | `IdentityPassportVerification.swift`, `PulsePassportIdentityClient.swift`: installation App Attest, stable operation id/session, nonce, `/passport/verify`, remote chip proof and holder binding; server verdict in claims | Stays host/optional service composition; standalone read has no mandatory server account and never claims this ceremony ran |
| Pulse retention | `PassportChipStore.swift`, `PassportChipRecord.swift`: encrypted SQLite, Keychain-wrapped column key, plaintext migration, original DG2/portrait, display photo, comparison binding, SOD-bound holder binding and erase registry | Existing Pulse behavior, not copied as a second store. Shared custody extraction requires foundation ownership, data/key migration and erasure tests first |
| Pulse evidence projections | `PassportChipEvidence.swift`: full proof digests, stable scan-time expiry, one field table for claim/lake mapping, explicit stored-local vs server verdict | Preserve byte semantics in adopter; do not rebuild lossy chip proofs from retained digest-only rows or upgrade a restored read to fresh authentication |
| Face reference | `PassportChipStore.referencePortrait` / `vouchFaceReference`, `PassportFaceComparison.swift` | Use original encoded portrait, not display JPEG. Biometric inference/model adoption is separate; the NFC port does not implement AuraFace or reuse the old bundled face model |

Pulse's former `Vendor/NFCPassportReader` was retired because Pulse and `IdentityEvidencePassport` must resolve one package identity. The identity checkout is the current shared reader source. Keep `VENDORED.md`, `provenance.json` and `import-manifest.json` distinct: upstream attribution, history and current imported bytes are different evidence.

### Behaviors that must survive unchanged

- One live NFC session, exactly-once first terminal outcome, continuation armed before begin, caller released only by matching invalidation, cancellation and stale-tag generation fencing.
- In-session tag-loss recovery resets per-tag model/protocol/queue state and restarts polling while retaining access key/challenge/session ownership; terminal errors do not fall through to BAC or another chip-authentication key.
- APDU status/secure-message verification, continuation limits, PACE domain/point/token checks, BAC reply/nonces/channel installation and protected-group retry bounds.
- Passive authentication occurs after transport closes; chain, SOD signature and group hashes remain separate from access success. Failed AA/CA is refused; unperformed is explicit. Remote CA is last, and only its terminal verifies its answer.
- Exact full DG2 bytes and original encoded portrait remain available with their SOD digest. Display JPEG is a separately re-encoded derivative; DG2 is absent from ordinary upload group maps. No restoration creates a fresh read.
- Host read failures/cancellation do not overwrite a retained verified passport. New scans void prior holder/comparison associations. Holder binding is tied to the retained SOD; old comparison results are hidden when their bound display-photo hash changes.

### Explicit follow-up contracts

The current portrait helper selects SHA-1/256/384/512 by digest hex length. Binding the public algorithm identity directly to EF.SOD, SHA-224/other algorithm coverage and extraction-proof hardening require explicit contract/vector changes rather than an undocumented port adjustment. Local trust-anchor success is not proof of current revocation/server policy. Malformed-chip parser robustness remains a named review track; normal interoperability and synthetic consistency do not establish fuzz coverage.

The initial iOS port must not silently import identity storage, networking, app names, bundled CSCA lists, real passport fixtures or models. Shared durable custody remains a foundation task; Android NFC remains planned until separately built and exercised. Native UI, installed physical passport reading, transient pull-away recovery, cancellation and accessibility acceptance each need their own current-package receipts.

### Host regression inventory for adopter migration

The donor app suites are retained in Pulse because their implementations depend on host ceremony, local custody and Worker contracts. They are required migration regression coverage, not claimed destination executions:

| Pulse suite | Behavior to retain when switching the adopter |
| --- | --- |
| `IdentityPassportSessionStateTests`, `IdentityPassportPreparationControllerTests`, `IdentityPassportPreparationFailureTests` | Complete stable attempt replay after ambiguous transport, challenge reuse for repositioning, bounded conflict/expiry/stale-time rotation, stale async failure fencing, cancellation before session/nonce and typed localized errors |
| `PassportVerifySubmissionTests` / `PassportHolderBindingStoreTests` | Exact App Attest domain/payload envelope and authorization, nonce-to-eight-byte AA challenge, required SOD/certificate, remote CA response, server verdict preservation, SOD-bound holder binding and new-scan/reset invalidation |
| `PassportFaceCompletionTests` | Exact face completion envelope, original portrait reference digest and full DG2 algorithm/digest without image upload |
| `PassportChipStoreTests` | PII/proof-digest retention, DG2 exclusion, encryption and wrong-key refusal, retired-fixture exact matching, display/original artifacts, comparison-photo binding, erasure failure reporting and retry |

The destination tests are imported separately by the test-port inventory, including Pulse-only preflight checks where the identity donor suite did not already cover the same production reader. Re-running Pulse's tests before its dependency changes would not establish destination parity; both packages must resolve the new source/artifact for adopter acceptance.

### Reviewed destination deltas from the donor

19 October 2026: the DG2 JPEG recognizer no longer requires the exact JFIF APP0
prefix. Generated JPEGs with an initial comment or without APP0 reproduce the
previous refusal and exercise byte-preserving extraction plus actual ImageIO
decode. A truncated JPEG remains refused. This is a destination compatibility
repair, not a change to SOD verification or a physical-interoperability claim.

This extraction preserves the donor implementation except explicitly attributed destination changes; donor files are not patched in place.

| Destination patch | Source defect / boundary | Exact reviewed change and evidence status |
| --- | --- | --- |
| Secure-message response authentication | Inherited `SecureMessaging.unprotect`: when computed MAC exceeds eight bytes (AES CMAC), the donor replaced it with the supplied MAC's first eight bytes, making an eight-byte forged MAC compare equal. Malformed DO87/DO8E lengths could also index beyond input; DO99 used `&&` when either malformed tag or length must fail. | Compare the supplied eight wire bytes against the locally computed MAC's first eight bytes, accumulating XOR differences. Parse only response payload bytes, bound DO87 and require cipher-block alignment, require exact DO99 tag/length and exact DO8E length/no trailing bytes. Authenticate before decrypting; reject malformed ISO padding. Source diff independently reviewed; regression/native execution is recorded separately by the root validation receipts. This is a deliberate narrow security fix, not claimed byte parity. |
| BER length safety | Inherited `Utils.asn1Length` indexed an empty input and truncated `0x81`/`0x82` lengths. | Guard all required length bytes before reading; preserve accepted short/one-/two-byte lengths and unsupported-length failure. Source reviewed; malformed-input suite execution remains a separate receipt. This does not establish complete chip-parser fuzz safety. |
| MRZ platform dependency | Donor camera interruption observation used ambient `NotificationCenter.default`. | Require an explicit host-supplied notification center; camera graph/late-frame/generation/stop behavior stays in the extracted driver. Intentional constructor change requires API snapshot review. |
| MRZ camera selection — 23 October 2026 | The passport donor fixed capture to the physical rear wide camera. The existing identity SDK document camera already restored virtual-first selection in `245e086` to let iOS switch constituents for close focus. | Port that exact selection order, resolution/ID tie breaking and native automatic switching, baseline zoom clamp and continuous AF/AE into internal `PassportMRZCapture` code. The source registry pins both original camera files at `0a1d0a0` and their exact hashes; six selection fixtures move with the port. Device identifiers remain internal tie breakers. A reviewed diagnostic records only fixed lens kinds and actual scalar camera settings after startup. Full-frame accurate Vision OCR and public readiness/lifecycle contracts remain unchanged. No Document dependency, distance inference, performance guarantee or physical camera acceptance is implied. |
| MRZ names after verified read — 23 October 2026 | The vendor model prefers expanded DG11 display names, while the correspondence contract compares the printed MRZ with authenticated DG1. | Select DG1 element `5B` using the existing vendor fallback split/filler/trim formatting. Keep raw DG11 bytes and all verification/mismatch rules. Four native actual-mapper tests verify generated public CSCA/DSC/SOD fixtures, shortened MRZ versus expanded DG11, absent DG11, genuine name mismatch and signed-DG1 tampering. An isolated return to the old mapping fails the new correspondence regression. These are synthetic tests, not a physical diagnosis by themselves. |
| Product split | Donor wrapper combined neutral public values, iOS vendor adaptation and identity-storage custody. | Keep neutral values in `PassportSDK`, iOS adapter in optional `PassportNFC`, camera/preview separate. Package-scoped constructors/helpers bridge same-package targets without making an arbitrary public authenticated-portrait constructor. Durable identity storage remains unported. |

The secure-messaging fix is confined to the destination. Existing production Pulse installations still use their existing reader until the separately validated adopter migration. A verified positive response plus forged-MAC/malformed-framing regressions are required to close this change; a source diff is not proof of physical passport interoperability.

The durable source registry currently covers 18 extracted runtime files and 47 supplier files, with exact upstream/OpenSSL identity and source/destination hashes. Test provenance and the required execution identities are registered separately; source presence and registered identities do not imply test execution.
