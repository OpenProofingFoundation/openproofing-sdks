# App and SDK Architecture Standard

**Document ID:** APP-ARCH-001  
**Revision:** 0.2  
**Date:** 2026-10-16  
**Status:** Governing requirements for new and changed SDK/app work; adoption and execution evidence are tracked separately.  
**Scope:** Kenshiki capability SDKs, their optional native UI, shared foundations, reference/adopting apps, and the client/BFF contract.

This revision records the owner-approved monorepo decision. The original repositories are retained as migration sources; their histories are imported without squashing. Product packages and versions remain independent. The frozen verification/reference snapshots are indexed in `governance/imports.json`; their source-code links refer to the original identity SDK checkout.

## 1. Authority, scope and current state

This document governs how the system is built. [SPEC-IDBIO-200](../references/edge-verification/SPEC-IDBIO-200.md) governs biometric/document verification methods, evidence and vendor removal. The [boundary contract](../references/boundary-contract.md) governs the existing reusable SDK's neutral/host/adapter roles. These documents are complementary; this standard does not silently change a deployed API or wire format.

**GOV-01.** Every adopting repository MUST identify this document and the applicable revision in its architecture index, `AGENTS.md` and `CLAUDE.md`. Agent guidance points to the same authority; it MUST NOT maintain a competing architecture. Changes to a governing rule require a reviewed document/guard change and an affected-adopter inventory.

**GOV-02.** MUST and MUST NOT are mandatory requirements. A requirement, an implementation and evidence that the implementation works are distinct records. A requirement with no implementation is planned work, not an executed check. A static guard is not a device test. Existing gaps MUST be named rather than silently exempted or described as passing.

**GOV-03.** The owner's explicit constraints are foundational: native UI on each platform; **NO LOGIC IN SWIFTUI EVER**; all authored user-facing text is localizable; the entire design system is JSONC; accessibility is a release requirement; security/storage mechanisms share contracts and implementation; the BFF retains server authority; guards/QA/CI enforce the architecture.

| Area | Located implementation or current artifact | Adoption still required |
| --- | --- | --- |
| Biometric and document SDKs (`biometric/`, `document/`) | Independent packages/QA; biometric portable portrait/math, optional C++ aligned inference and optional iOS capture/preview extraction | Document extraction; mobile biometric inference, complete lineage/custody and physical qualification; ledgers carry actual execution scope |
| Shared infrastructure | SQLite, custody/erasure and App Attest source exists in the identity SDK | Independently consumable common foundation and Android implementations |
| Presentation resources | Shared JSONC compiler/catalog, generated Swift/Kotlin resources, pure controllers and UIKit/Android reference hosts exercise simulated workflows; see `reference-apps/` | Capability evidence integration, expanded rendered/device coverage and actual VoiceOver/TalkBack acceptance; see the native criterion matrix |
| Passport (`passport/`) | Imported native scaffold, QA framework and original build/API receipts in `kenshiki-sdks` | Extract existing MRZ/NFC and cryptographic adapters with their behavior/assurance suites |
| NIST | Pinned official 1:1 tooling/null-reference mechanics and portable C++ face primitives; optional aligned-input CPU inference | Actual FRTE recognition adapter, template encoding and official qualification |

The rows are an architectural inventory, not a declaration of shipped cross-platform capability. Current source and artifact evidence belongs in each capability's ledger. Future implementation sequencing belongs in Appendix A.

## 2. Capability and shared-foundation boundaries

**MOD-01.** `kenshiki-sdks` is the single source repository for the biometric, document and passport capability products, located in `biometric/`, `document/` and `passport/`. Their product identities remain Kenshiki Biometric SDK, Kenshiki Document SDK and Kenshiki Passport SDK. Each MUST expose independently versioned public APIs and an independently runnable native sample for its declared path, without another capability SDK, the product identity SDK or a Kenshiki backend account as mandatory dependencies. Optional adapters and presentation products remain explicit.

| Capability | Owns | Exports to composition |
| --- | --- | --- |
| Biometric (face matching) | Detection/alignment, embedding, comparison, quality/admission and declared PAD; optional selfie capture | Model/policy-scoped observations, source-bound portrait/selfie lineage and explicit outcomes |
| Document | Optical capture, geometry, Cadastral evidence, OCR/barcode, portrait extraction and declared document checks | Source-bound fields/portraits, measurements, provenance and check observations |
| Passport | MRZ capture/parsing and NFC orchestration, access protocols and credential/portrait verification | Separately reported access, passive/chip authentication and authenticated portrait provenance |
| Identity composition | Coordinates capabilities, issuer/phone services, platform proof and the product decision | Complete attempt state and server decision receipt |

**MOD-02.** A shared foundation provides selected products for evidence contracts, protected SQLite/durable storage, key custody/signing, platform attestation and clock/cancellation/erasure lifecycle. It MUST NOT depend on capability SDKs, app features, UI, BFF DTOs or enrollment policy. Capabilities MUST NOT import product composition or one another merely to obtain common infrastructure.

```text
Native app renderers -> public presentation state/intents
Native app controllers -> capability public APIs + optional BFF/service adapters
Biometric / Document / Passport -> shared contracts + selected foundation products
Shared foundation -> contracts + native platform/system mechanisms
BFF/service adapters -> product server contracts
NIST C++ adapter -> selected portable face core/artifact; no mobile UI/attestation dependency
```

**MOD-03.** A process resolves one compatible foundation implementation/version. Copying SQLite/key/attestation implementations into each SDK is forbidden. Products are modular so a headless caller can select required mechanisms without importing UI or a proprietary backend. Shared resources have one versioned source of truth, not per-repository forks. Shared foundation denotes selected, independently consumable products; it is not a fourth capability. Shared source lives in `foundation/`, common schemas/vectors in `contracts/`, and JSONC design/localization sources in `design-system/`. Source/package ownership is recorded before extraction.

**MOD-04.** Preserve the rule: **the host supplies names, identities and locations; the SDK owns security mechanisms.** Hosts select namespaces, storage roots, application identifiers, consent/retention profiles, clock inputs and attributed calibration. Public injection MUST NOT let a host silently weaken key construction, protection classes, integrity verification or durable erase semantics.

**MOD-05.** Passport is a separate capability in `passport/`. MRZ capture/parsing, NFC orchestration, passport access protocols and passport credential/portrait verification belong there; `document/` owns the optical document scope in the table. SPEC-IDBIO-200 §2.1 MUST record this revised placement before implementation extraction. mDL remains separately scoped; a passport reader does not imply mDL support.

## 3. Shared contracts, custody and platform services

**CON-01.** Neutral APIs return typed data, measurements, uncertainty, source lineage, reason codes and explicit unavailable/unsupported/failure states. They MUST NOT return authored user-facing prose, vendor-owned DTOs or an unqualified product identity-acceptance flag. A capability-specific observation is scoped to its exact method/model/policy; only authorized composition decides the complete identity claim.

**CON-02.** Every public evidence contract specifies schema/API version; units, clocks and coordinate conventions; source and derivative digests; model/preprocessing/calibration identity; supported inputs and size/depth bounds; unknown-field/version handling; cancellation; lifetime/ownership; and error/recovery semantics. Swift, Kotlin, C++ and server implementations, where applicable, consume common positive and negative fixtures.

**CON-03.** Portrait handoff preserves original capture identity, exact consumed portrait bytes, source/derivative hashes, orientation, crop/warp/mask transformations, selection/ambiguity and original/restored lineage. No SDK exposes a vendor document object as this contract. Old embeddings and receipts retain their original model/policy identity.

**STORE-01.** SQLite storage specifies schema/migration versions, transaction boundaries, concurrency, file-protection/encryption/key ownership, namespace isolation and recovery. SQLite is not itself an encryption guarantee. Transient disk/protection errors and failed migrations MUST preserve the canonical database rather than trigger destructive corruption recovery.

**STORE-02.** Every persisted store belongs to an enforced erase inventory: database, WAL/SHM, caches, corruption quarantines, journals and key records. Erasure fences new publications and in-flight work, persists recovery intent and survives interruption. Reopen, retry, migration, disk-full, key-unavailable and erase-race tests are mandatory when storage is introduced.

**KEY-01.** The key contract identifies purpose, algorithm, key ID, namespace, backing/security level, access policy and lifecycle. Private keys and raw secrets MUST NOT cross the public API or enter logs. Rotation, invalidation, reinstall, missing keys and recovery are explicit states. Retained ciphertext MUST NOT silently cause creation of an unrelated replacement key.

**ATTEST-01.** Evidence signing, platform attestation, biometric inference and camera authenticity remain separate claims. Apple Secure Enclave/Keychain and App Attest, and Android Keystore/available hardware backing and Play Integrity, use platform-specific adapters under common conceptual contracts. The result records the actual mechanism/capabilities; common API shape does not mean identical assurance. Unsupported, unprovisioned and unavailable states remain visible.

**ATTEST-02.** Registration/challenges, exact request-byte binding, key-level sequencing/counters and operation recovery belong in versioned contracts. One coordinator owns operations sharing a platform proof key where required. Concurrent assertions, out-of-order arrival, replay, response loss and challenge consumption require explicit tests. Existing native-face/evidence byte contracts MUST NOT be silently unified by foundation extraction.

## 4. Client and BFF authority

**BFF-01.** The client acquires/processes local evidence, constructs the permitted lineage and drives local feature state. The server authenticates the installation and platform proof, enforces freshness/replay/expiry, resolves authoritative external receipts and subject/capture/attempt binding, and applies the product policy. A signed client success flag or an opaque receipt ID cannot independently authorize acceptance.

**BFF-02.** Neutral SDKs depend on service ports, not product HTTP routes or credentials. A named adapter owns DTO mapping, transport, authentication, version negotiation and provider-specific behavior. Views never invoke the BFF. Provider credentials and attestation-verification secrets remain server-side.

**BFF-03.** Requests and results bind installation/application, session, generation, attempt, operation, challenge, source/derived artifacts and policy. Retries and result readback are idempotent under the authenticated contract. Cancellation/restoration cannot resurrect superseded operations or combine different attempt generations. An outage is not a biometric mismatch.

**BFF-04.** The server returns typed outcomes, reason codes and structured arguments. Native presenters/localization catalogs own user wording. Logs and telemetry exclude identity-bearing payloads. A selected operation explicitly declares any disclosure of raw images, portraits, embeddings or identity fields and their recipient/retention; no generic evidence envelope authorizes new disclosure.

**BFF-05.** Each optional native sample can exercise a local deterministic service port. Live BFF, issuer, carrier and platform-proof execution have separate integration receipts. A local fake service is never represented as a live provider success.

## 5. Native presentation

The following sections define required architecture and acceptance. Existing implementations and enforcement coverage are recorded in the adoption appendix; a requirement here does not imply an
implemented guard.

**UI-01 — Native rendering.** iOS presentation MUST use SwiftUI/UIKit and Android presentation MUST use Compose/Android Views. Each platform retains native navigation, input, accessibility and
lifecycle integration. Optional wrappers consume public native contracts and MUST NOT introduce a second workflow implementation.

**UI-02 — NO LOGIC IN SWIFTUI EVER.** SwiftUI views are renderers. The same strict separation applies to UIKit, Compose and Android Views: renderers MUST NOT own application behavior. They consume
immutable presentation state and emit typed intents. Declarative layout, selection among supplied visual variants and forwarding an interaction are rendering; validation, workflow decisions and
computation of derived application state are not.

**UI-03 — Controller ownership.** Plain Swift/Kotlin controllers and tested presentation mappers own state transitions, validation, policy evaluation, formatting, SDK/BFF orchestration, permission
decisions, asynchronous work, retry, timers, cancellation, persistence and restoration. Domain controllers remain independent of UI frameworks. A platform adapter may translate lifecycle or permission
callbacks into controller events; it MUST NOT decide their workflow consequences.

**UI-04 — No hidden view logic.** Moving behavior into a view helper, property getter, modifier, binding setter or callback does not satisfy UI-02. View lifecycle hooks, SwiftUI `.task`/`onChange` and
Compose effects MUST NOT initiate workflow work. Platform wiring forwards typed events to the owning controller. Event handlers dispatch prepared intents without validation, transport or workflow
mutation.

**UI-05 — Typed presentation contract.** Presentation state MUST explicitly represent loading, readiness, progress, error, recovery, completion and cancellation where applicable. It carries prepared
message values, enabled actions and semantic accessibility state. It MUST NOT expose mutable database handles, model runtimes, signing keys or transport clients to renderers.

**UI-06 — Dependency enforcement.** Build-graph and source guards MUST discover every production presentation root and reject unclassified roots. Renderers depend on public presentation contracts,
generated resources and approved native UI adapters; they MUST NOT import SQL, key custody, inference, networking or BFF implementations. Transitive dependency checks enforce the same direction.

**UI-07 — Behavioral acceptance.** Controller tests MUST exercise transition order, duplicate events, cancellation, retry, lifecycle interruption and restoration without launching a UI. Native UI
tests verify that intents reach controllers and presentation states render correctly through public APIs. Adversarial guard fixtures cover logic hidden in helpers, closures and newly introduced source
roots.

## 6. JSONC design system

**DS-01 — Entire design system.** Versioned JSONC is the authoritative source for semantic colors, typography and scaling, spacing, dimensions, shapes, borders, elevation, motion, icons, component
anatomy, variants and interactive states. App and SDK presentation MUST consume these definitions. Platform-specific behavior and mappings are explicit parts of the design contract.

**DS-02 — Definition and implementation.** JSONC defines visual properties and component contracts; native code implements rendering and OS interaction. Component schemas identify slots, semantic
roles, supported variants, states and token references. JSONC MUST NOT become an executable workflow language or contain security policy, secrets, BFF locations or biometric thresholds.

**DS-03 — Strict schema.** Schemas MUST reject duplicate keys, unknown fields, incorrect units, invalid values, unresolved or cyclic references, unsupported platform mappings and incomplete required
variants. Comments and trailing commas are parsed as JSONC without corrupting string contents. Parser and schema versions are pinned.

**DS-04 — Typed native generation.** A deterministic generator MUST produce typed Swift/Kotlin accessors and required native resources from the same sources. Generated files record source, schema and
generator identity. A read-only `--check` mode MUST fail when committed output differs; CI MUST NOT regenerate and accept changes silently. Authored native files MUST NOT duplicate generated token
definitions.

**DS-05 — Semantic use.** Renderers MUST reference semantic tokens and component variants rather than handwritten colors, fonts, dimensions or animation parameters. Geometry derived from an actual
camera/frame coordinate system remains measured input, not a styling token. Unavoidable native API constants require a narrowly scoped, reviewed rule with executable guard fixtures; they cannot
provide a general bypass for visual literals.

**DS-06 — Platform adaptation.** Native implementations MUST respect system text scaling, contrast preferences, reduced motion, safe areas, input insets and appearance. JSONC maps semantic roles to
these mechanisms. A fixed typography table MUST NOT disable Dynamic Type or Android font scaling.

**DS-07 — Host overlays.** Branding and adopter overlays MUST use the same schema and explicit deterministic precedence. They MUST NOT remove required component semantics or weaken accessibility
minima. Invalid overlays fail validation before packaging; remote configuration MUST NOT bypass the versioned design contract.

**DS-08 — Design acceptance.** Generator tests cover invalid schemas, duplicate keys, references, overlays, platform mappings and deterministic output. Native snapshots cover component variants and
interactive states in light/dark appearance and supported text scales. Static contrast tests evaluate declared foreground/background pairs; rendered tests evaluate compositing, opacity, live-camera
backgrounds and actual text layout.

JSONC's comment/trailing-comma syntax is documented by the [Microsoft JSONC parser](https://github.com/microsoft/node-jsonc-parser). The repository's existing
`Examples/ReactNativeCaptureHost/generate-ui-resources.py` is a local precedent for strict JSONC validation and generated-output checks; it is not the definition of the cross-platform native resource
format.

## 7. Internationalization

**L10N-01 — Every authored user-facing string.** All visible and spoken application text MUST originate in versioned JSONC localization catalogs under a strict schema. This includes labels, placeholders, instructions, consent,
errors, recovery, status/progress, notifications, help, accessibility names/hints/values/custom actions, permission rationales and application-authored OS permission descriptions. Standard OS-owned
text follows the OS locale; application-authored text presented inside OS UI remains catalog-owned.

**L10N-02 — Library boundary.** Headless SDKs return stable reason codes and structured arguments, never prose for the holder. The host or optional presentation package owns wording. Raw exception
descriptions, vendor responses and diagnostic messages MUST NOT be displayed as fallback copy. User-provided values and document contents are data, not translatable application prose.

**L10N-03 — Typed messages.** Catalogs MUST define stable message identifiers, typed placeholders and translator context. Complete sentences use validated plural/select forms where needed. Sentence
concatenation and substitution of English fragments are prohibited. Generation MUST reject duplicate keys, malformed syntax, missing required branches, incompatible placeholder types and key/argument
drift between shipped locales.

**L10N-04 — Native resources.** Catalog generation MUST produce typed Swift/Kotlin message APIs and native resources where required, including Android string/plural resources and iOS
`InfoPlist.strings` permission descriptions. Accessibility-only text has the same localization and completeness requirements as visible text. No native resource file may become an unmanaged second
source of authored copy.

**L10N-05 — Locale and fallback.** Locale resolution MUST preserve relevant language, script and region distinctions and declare a deterministic fallback chain. The release declares supported locales
and its fallback locale. Shipped locales MUST be complete; silent per-key fallback is prohibited. Missing keys and unresolved placeholders fail development/CI checks. Shipping one supported language
initially does not permit hardcoded user-facing strings.

**L10N-06 — Formatting and direction.** Presenters use platform/ICU locale rules for dates, numbers, units and plurals. Exact identifiers, MRZ fields, hashes and protocol bytes retain their defined
representation. Native layouts use semantic leading/trailing directions and correct bidirectional isolation for identifiers embedded in prose; icons mirror only when their meaning requires it.

**L10N-07 — Locale acceptance.** Tests MUST include expanded pseudolocalization, RTL and mixed-direction content, non-Latin text, supported plural categories, locale fallback and all
permission/accessibility resources. Critical content and actions MUST remain available without clipping at supported font scales. Translation review covers instructions and consent before a locale is
released.

**L10N-08 — String guards.** Manifest-derived source/resource checks MUST inspect user-facing sinks, including accessibility setters, alerts, notifications and permission files. They reject raw
authored literals and display of raw errors. Generated outputs and catalogs are validated separately. Synthetic mutations MUST demonstrate that newly added UI files and native resources cannot evade
the checks.

## 8. Accessibility

**A11Y-01 — Acceptance standard.** Each released native user journey MUST meet applicable WCAG 2.2 Level A and AA success criteria using a maintained native criterion matrix. The project adopts these
requirements for native software; [WCAG2ICT](https://www.w3.org/TR/wcag2ict/) provides informative interpretation and does not itself create a native conformance standard. The source criteria are
[WCAG 2.2](https://www.w3.org/TR/WCAG22/).

**A11Y-02 — Criterion matrix.** The matrix MUST enumerate every A/AA criterion with its native interpretation, applicable screens/states, owner, verification method and acceptance evidence. A
not-applicable or essential-function determination requires a criterion-specific rationale. The following mappings are required coverage, not a replacement for the full matrix.

| Area / representative criteria | Required native behavior |
| --- | --- |
| Alternatives, structure and semantics: 1.1.1, 1.3.1–1.3.3, 4.1.2 | Correct accessible names, roles, values, grouping and reading order; decorative content excluded; instructions do not depend on sight, position, sound or color alone. |
| Orientation and resizing: 1.3.4, 1.4.4, 1.4.10 | Usable supported orientations and native text scaling/reflow without lost content or actions; essential restrictions documented by criterion. |
| Contrast and color: 1.4.1, 1.4.3, 1.4.11 | At least 4.5:1 ordinary text, 3:1 qualifying large text and 3:1 required non-text information; color-independent meaning; legible camera overlays. |
| Input and focus: 2.1.1–2.1.2, 2.4.3, 2.4.7, 2.4.11 | Keyboard/switch operation, no traps, logical focus, visible and unobscured focus, predictable focus after navigation and errors. |
| Pointer and motion: 2.5.1–2.5.4, 2.5.7–2.5.8 | Alternatives to complex gestures, dragging and motion where required; cancelable activation; accessible names contain visible labels. |
| Timing and flashing: 2.2.1–2.2.2, 2.3.1 | Adjustable time where required, controllable nonessential motion, no prohibited flashing. |
| Understanding and assistance: 3.1.1–3.1.2, 3.2.1–3.2.2, 3.2.6, 3.3.1–3.3.4 | Correct language metadata, predictable operation, consistent help, accessible errors/instructions and confirmation where required. |
| Entry and authentication: 3.3.7–3.3.8 | No needless repeated entry or inaccessible cognitive tests; supported paste/autofill and authentication assistance remain available. |
| Status: 4.1.3 | Meaningful asynchronous status and recovery are programmatically exposed without unnecessary focus changes or announcement flooding. |

**A11Y-03 — Native interaction minima.** Interactive bounds MUST be at least 44 × 44 points on iOS and 48 × 48 dp on Android, with no overlap that blocks adjacent controls. These project/platform
minima are not an assertion that WCAG's CSS-pixel measurements equal native points or dp. Component and host overlays MUST preserve the minima.

**A11Y-04 — Capture accessibility.** Face, document, MRZ and NFC instructions MUST have accessible equivalents and stable focus while capture progresses. Visual alignment, movement prompts, audio and
haptic feedback MUST communicate equivalent required information as applicable. Any essential sensor/movement requirement is assessed against specific criteria and documented with the supported
assistance or alternative journey; biometrics is not a blanket exemption.

**A11Y-05 — Automated acceptance.** Native UI suites MUST audit semantics, target bounds, contrast where measurable, focus/navigation, text scaling and all critical workflow states. Snapshot matrices
include appearance, large accessibility text, RTL and reduced-motion settings. Relevant checks run on the actual built native artifact, not only generated resource files.

**A11Y-06 — Assistive-technology acceptance.** Release evidence MUST include complete happy, denial, error, retry, cancel and recovery journeys using VoiceOver on iOS and TalkBack on Android, plus
applicable keyboard, switch and voice operation. Record artifact identity, device/OS, locale, settings, journey, findings and disposition. [Apple's testing
guidance](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app) and [Android's testing
guidance](https://developer.android.com/guide/topics/ui/accessibility/testing) combine automated testing with assistive-technology evaluation.

**A11Y-07 — Ownership and evidence.** Shared presentation packages own accessible components; adopting apps own composed journeys, navigation, permission UI and host copy. Both must supply their
matrix evidence. Static guards establish inspected structural properties, automated audits establish checked artifact/state properties, and manual acceptance establishes exercised journeys. No single
scanner result substitutes for the release criterion matrix.

## 9. Guards and quality assurance

**QA-01.** Every production target, source language, resource generator, binary, dependency, example and pipeline lane has a declared role and enforced inventory. Discovery follows build manifests, not a remembered directory list. Unknown, unreadable, missing, renamed or hidden expected inputs fail closed. Source redirection and symlinks cannot create unscanned production code. Generated exclusions require successful read-only regeneration checks.

**QA-02.** A guard has adversarial tests against real mutated source/configuration. Required mutations include hidden targets, a forbidden dependency, view logic in helpers/closures, raw localized text, invalid JSONC, private API access, dropped jobs, conditional steps, early successful exits and stale/empty receipts. Keeping expected command text in unreachable shell code MUST NOT make CI green. New capability products accept zero new debt; broad suppressions and source-marker exemptions are forbidden.

**QA-03.** Native entry points are structurally enforced or compared with a reviewed canonical runner. Required commands cannot be replaced by echo wrappers, filtered executions or softened exits. Changes to working directory, shell, environment, containers or execution context require guard coverage. A passing configuration substring search alone is insufficient.

**QA-04.** Behavior tests accompany the implementation they protect in the same change. They exercise failure, malformed/untrusted inputs, cancellation, concurrency, interruption/recovery and compatibility, not only the happy path. Required selections are verified as executed; zero tests or silently skipped required suites are failures. A scaffold with no behavior implementation records that status explicitly.

| Component introduced or changed | Mandatory additional coverage |
| --- | --- |
| Native SDK capability | Pure/unit and contract tests; iOS device/simulator compilation; actual simulator execution for iOS behavior; Android JVM and relevant instrumentation; public API and packaged-content inspection |
| Storage/keys/attestation | Namespace isolation with two adopters in one process; migrations/reopen/corruption/disk/protection failures; erase fences/races; key lifecycle and crypto vectors; proof registration, counters, challenge/replay and response-loss recovery |
| Native UI/components | View-purity/dependency guards; JSONC/catalog generation; controller tests; rendered snapshots/semantics; localization, RTL/scaling and accessible full journeys |
| Parsers/native bridges | Synthetic corpus, fuzzing and applicable sanitizers; malformed inputs; binary/dependency and symbol inspection; source/artifact provenance |
| Models/preprocessing | Pinned environment and manifests; training/calibration/test separation; subject/duplicate isolation; input/output/threshold parity across Python, Apple, Android and C++ where applicable |
| BFF/optional services | Real contract vectors, auth/expiry/replay and binding attacks, idempotency, missing/contradictory coverage, outages and recoverable retries |

**QA-05.** Physical key backing, camera behavior, NFC, platform attestations and assistive technologies require their applicable device/server evidence. Simulator mocks remain useful separate evidence. SDK integration changes require refreshed validation in every adopting app against its resolved SDK source/artifact; existing installations do not inherit new code.

## 10. CI and evidence contracts

**CI-01.** Required local commands and CI execute the same checks. Capability CI has separate visible lanes for guards, macOS tests, iOS device compilation, iOS simulator compilation/execution and Android build/lint/tests. Feature-specific instrumentation, native UI, JSONC/i18n/A11y, sanitizer/fuzz, shared-service and NIST lanes activate when their component is added. A platform lane cannot be removed because another platform is green.

**CI-02.** Pipelines run for pull requests and protected integration/release branches. Required jobs cannot be conditionally skipped or use `continue-on-error`; matrices cannot hide a required destination. Actions, toolchains and downloaded dependencies are pinned or have an explicit recorded drift policy. Binary caches MUST NOT hide missing sources or dependencies. Compiler warnings remain visible.

**CI-03.** Repository workflows and remote branch/ruleset enforcement are distinct controls. The repository records the required check names for `dev` and `main`; remote protection is verified separately. No document or workflow file alone establishes that GitHub blocks a merge. Publication/deployment credentials are isolated from ordinary read-only QA jobs.

**EVID-01.** Every guard/build/test/package/installation/device lane emits its own machine-readable receipt. It binds repository/revision/dirty state; relevant source, lockfile, schema, generator and resource hashes; platform/toolchain/SDK; command and configuration; required test IDs/counts; actual outcome; and artifact/log digests. Freshness and scope are checked. A guard receipt cannot stand in for a native build receipt.

**EVID-02.** Failed runs preserve evidence. Missing, stale, incomplete, empty or scope-mismatched required receipts fail the applicable gate. Reports distinguish source inspection, compilation, automated execution, packaged artifact, adopter integration, installation, physical acceptance and independent evaluation.

**EVID-03.** Evidence must be reviewable without exposing personal data or secrets. Synthetic/public permitted fixtures belong in source; biometric corpora, credentials, private keys and unapproved vendor/model resources do not. Real data and resulting artifacts remain in their declared external storage with access/retention controls. Hashes and categorical outcomes are still sensitive derived information.

## 11. Face training and NIST toolchain

**FACE-01.** Training, conversion and runtime share versioned artifact/preprocessing contracts. A library/loss name is not a delivered model. Each model pins source/code/data/weight permissions, training recipe, subject partitions, seed/checkpoint, input color/range/alignment, output representation and deployment conversions. Experimental sample data and provisional labels are identified; their results are not promoted into release calibration.

**FACE-02.** The local Mac toolchain supports MPS development plus CPU/reference export, ONNX checking/runtime comparison and Core ML conversion/parity. Android and NIST consume their selected compatible exports. A successful conversion or synthetic smoke test does not replace actual model/threshold parity.

**NIST-01.** The face capability includes a separately built C++ FRTE 1:1 algorithm adapter and local harness, followed by execution of NIST's official validation package. It MUST use the unmodified pinned official headers/API and applicable general specifications. It is not a Swift/Core ML-only wrapper and cannot require mobile platform services.

**NIST-02.** The current pinned review is API 6.0.1 and General Specifications 3.1. Qualification targets Linux x86_64 on NIST's specified Ubuntu 24.04.3 environment and C++20/g++ 13.3.0 compatibility. The source pin, execution requirements and announced effective dates are rechecked before submission. A newer development container or Apple Silicon emulation is a development receipt, not the prescribed qualification environment or a valid timing benchmark. [NIST specifications](https://pages.nist.gov/frvt/api/FRVT_common.pdf), [API](https://pages.nist.gov/frvt/api/FRVT_ongoing_11_api.pdf).

**NIST-03.** Harness coverage includes initialization before fork; actual post-fork extraction/comparison; single-thread execution; template roles/multiple-image and multiple-face behavior; required unsupported-function returns; grayscale/RGB and malformed inputs; failed/empty templates; finite scores; deterministic versioned template encoding; dependency/CPU-instruction compatibility; memory/failure behavior and measured timing. It MUST NOT manufacture successful templates from zero-filled vectors or infer fork safety from environment variables.

**NIST-04.** Record the exact selected artifact, compiler/ABI, OS, CPU, thread configuration and workload. Current API timing limits and published effective-date changes govern; internal budgets remain separate. Official validation, package generation, signing/encryption, submission, NIST execution and publication are separate evidence events. Neither local validation nor an FRTE result certifies PAD, document authenticity or the complete identity flow. [NIST participation and validation](https://pages.nist.gov/frvt/html/frvt11.html).

## 12. Change control and adoption

**CHANGE-01.** Public APIs, schemas, reasons, resources, foundation modules, generated output and BFF contracts have explicit versions and compatibility rules. Public API snapshots detect drift; the reviewer still determines versioning and migration. Stored evidence retains original identities and is not reinterpreted under a replacement model or policy.

**CHANGE-02.** An architecture change identifies affected SDKs/apps, source-of-truth ownership, dependency changes, migration/rollback, guard changes and required evidence. Retiring a vendor removes shipped runtime/model/resource/fetch paths and transitive dependencies. Renaming or feature-flagging a still-shipped vendor does not establish removal.

**CHANGE-03.** Agent instructions are operational entry points, not substitute standards. `AGENTS.md` names required reading, commands, scope/evidence rules and architecture constraints. `CLAUDE.md` references that same guidance. Neither may introduce an undocumented exception, and neither authorizes unrelated cleanup, publication or deployment.

## Appendix A. Adoption and implementation plan

Implementation planning is kept here; the preceding requirements are the enduring contract.

| Work package | Concrete next result | Completion evidence |
| --- | --- | --- |
| ARCH-A1 — governing authority | Adopt this standard in SDK/app indexes and both agent instruction files | Valid links, one identified revision, explicit existing/adoption status |
| ARCH-A2 — common contracts | Freeze source/portrait, storage/key/proof, presentation/intents and optional service ports before extraction | Shared schema/API fixtures, ownership/version compatibility and negative bindings |
| ARCH-A3 — shared foundation | Extract existing mechanisms into independently consumed products; implement Android counterparts | Separate native builds, namespace/isolation, migration/erase/key/proof tests and actual platform receipts |
| ARCH-A4 — native presentation resources | Schema/generate JSONC tokens, components, catalogs and native resources; pure renderers/controllers | Deterministic generation/drift, AST/source-sink guards, controller and rendered/native accessibility evidence |
| ARCH-A5 — capability extraction | Move each component together with its tests, fixtures and applicable assurance harness | Ledger/source hashes, standalone sample, platform/behavior/API/package receipts |
| ARCH-A6 — passport extraction | Implement the approved `passport/` boundary and align SPEC-IDBIO-200 before extraction | Reconciled document/repository boundaries and MRZ/NFC/trust/portrait contract |
| ARCH-A7 — NIST | Build the C++ adapter/local harness around the selected face artifact; execute official validation | Correct OS/ABI, fork/thread/template/error/timing tests, official package and submission provenance |
| ARCH-A8 — adopter/release gates | Refresh integrations and configured remote CI requirements | Required checks verified, native app artifacts, installation, device/A11y and release evidence |

Existing SDK source is preserved during this work. Capability developers coordinate through reviewed contracts and shared fixtures; one capability's extraction does not require rewriting the other. Repository creation/rename, extraction and release evidence are recorded separately.

### A.1 Current delivery and acceptance

[README.md](../../README.md) indexes implemented products and
[HANDOFF.md](../../HANDOFF.md) records the current runtime checkpoint and blockers.
Close hosted CI and Sonar findings on the exact revision, then complete physical
passport/selfie and native accessibility acceptance. Preserve source-bound
observations and independently consumable capability packages throughout.

### A.2 Remaining cross-platform and product work

Android live readers/capture/inference, document processing, complete producer
and ordered-derivation verification, durable product evidence adapters and the
actual FRTE recognition adapter remain separate delivery tracks. Carry relevant
synthetic vectors, adversarial tests, APIs and source/licence provenance with each
slice. Product adapters retain BFF acceptance, replay/freshness and policy authority.
Independent package consumption, platform qualification and release rights must
be established before a release or vendor-removal claim in an adopter.

### A.3 Portable portrait contracts

Swift, Kotlin and C++20 implement owned packed pixels, exact-byte hashes, complete
request bindings, model-scoped observations and in-memory operation fences. The
shared portrait/math vectors are executable contracts. Extend full source,
selection and ordered-derivation verification, portable template encoding and
artifact-specific parity without reinterpreting historical model/policy readers.
See [portrait/selfie v1](../../contracts/portrait-selfie-v1.md) and
[biometric products](../../biometric/README.md) for current interfaces and evidence.

### A.4 Model and inference qualification

AuraFace-v1 is the owner-selected development embedding baseline. The
[selection record](../model-selection.md) owns model roles, US development/training/data
requirements, weight rights and evaluation gates; the [artifact record](../../biometric/docs/auraface-baseline.json)
pins the selected graph. Apple alignment/inference and optional C++ aligned-input
inference are implemented. Android parity, calibrated recognition/PAD, trainable
checkpoint/gradient/export parity and the FRTE algorithm interface remain separate.

Qualify every tuned, exported or quantized derivative independently, with explicit
subject/session splits, numerical contracts, model cards and licences. The
external aligned-input experiment and synthetic runtime tests do not establish
recognition accuracy, a training recipe, deployment readiness or NIST timing.

The retired `BiometricVisualAssessment` experiment added a separate offline Liquid
LFM2.5-VL-1.6B 4-bit image-pair observation on physical iOS. Its
[contract](../../biometric/contracts/visual-face-assessment-v1.md) fixes original
input hashes, aspect-preserving preprocessing, the frozen artifact/profile and
bounded structured output. Its runtime and app orchestration were removed on
22 October 2026; A.12 records the retirement boundary. Existing archived visual
output does not alter cosine scoring or authorize identity acceptance.

### A.5 Native selfie acquisition

Optional `BiometricCapture` and `BiometricCapturePreview` retain TrueDepth admission,
owned color/depth snapshots and a bounded PNG-to-RGB boundary. The reference
app's reviewed selfie feeds the separate inference adapter, never a synthetic
comparison engine. [Capture scope](../../biometric/docs/capture-extraction.md)
retains modality, calibration, resource and derivation limits.

Complete physical denial/retry, rotation, interruption, cancellation and accessible
guidance evidence. Android acquisition and complete product custody/proof adapters
remain separate; the portable core and Linux/NIST path stay independent of ARKit.

### A.6 Passport maintenance and adopter migration

The iOS port includes MRZ capture/manual input, the patched native reader and
credential/portrait observations. Preserve the original transport, teardown,
CoreNFC-sheet lifecycle and post-transport authentication behavior. Maintenance
or adopter migration must verify current source revisions, attributed supplier
patches, native protocol tests and trust configuration; do not reconstruct an
older unpatched upstream reader. [The ledger](../../passport/docs/extraction-ledger.md)
and source inventories retain those boundaries.

The portrait helper currently infers the digest algorithm from the SOD hash's hex
length and supports SHA-1/256/384/512, without independently parsing the EF.SOD
algorithm identifier or supporting SHA-224. Changing algorithm identity requires
its own vectors and compatibility review. DG2 admission relies on the verified
reader/parser for portrait extraction lineage. Do not accept arbitrary portrait
bytes as authenticated or flatten missing, failed and unavailable protocol states.
Passive authentication does not establish server nonce freshness, revocation,
complete identity acceptance or a supported anti-cloning mechanism. Android reader
qualification and product-adopter migration remain separately evidenced.

### A.7 Guided native passport and selfie reference journey

The iOS reference app implements a single Passport → Selfie → Result journey.
It composes existing capability mechanisms without changing NFC/capture/inference
math, model profiles or BFF authority. Standalone capability examples
remain separately accessible from the introduction.

`PassportFaceJourneyController` owns one in-memory session, ordered source/selfie
handoffs, disclosure state, retake, cancellation and interruption. Existing passport,
capture and comparison controllers retain their mechanisms. Native hosts prepare
localized screens and navigation; renderers only consume prepared state and emit
typed events. A single navigation root is updated in place for processing/results.
Session replacement waits for the retired passport controller's read/camera
settlement before mounting and admitting the next acquisition. This wait is
generation-fenced and remains cancellable without replaying a read.

| Slice | Behavior and invariant | Required evidence |
| --- | --- | --- |
| Passport | Explicit Begin admits capture only after native visibility. Manual input remains a fallback. One confirmation starts the chip read; result shows the original portrait and Continue to selfie. | Visibility/withdrawal tests; existing NFC-sheet/resign-active and protocol tests; native one-confirmation journey. |
| Selfie | Continue to selfie explicitly admits acquisition after visibility. Review offers Compare faces and Retake. Original evidence and late-result fences remain intact. | Native host test through actual review/selection callbacks; exact image and session binding; cancellation and revoked pending admission. |
| Result and recovery | One combined passport/comparison summary. Details expand on demand. Retake retains only the current passport; Done/Cancel clear the session. Backgrounding clears evidence and requires a new Begin. | Duplicate/retired/reentrant callback tests; combined visible result and late-completion refusal; real device and VoiceOver acceptance separately. |
| Boundaries and delivery | SDKs remain independently consumable. The old examples use their existing isolated workflows. Comparison remains a cosine observation without a calibrated match or identity verdict. | Source inventory and adversarial boundary tests, generated-resource drift, affected native lanes and exact signed build/install receipts. |

The owner-authorized passport checkpoint adds local persistence to this journey.
`PassportCaptureStore` is an app-owned SQL adapter over `KenshikiProtectedStorage`;
it does not duplicate key custody, encryption, file protection or durable erasure.
Its dedicated schema has a checksummed migration history, transactional initial
creation/replacement, exact source digests and bounded archival data. Future schema
versions and malformed bindings fail closed while preserving the canonical store.
The stored record is a separate app value, never a manufactured fresh SDK read.
Successful NFC completion invokes persistence before the passport result becomes
available. A pending commit blocks portrait handoff; a failed commit retries the
same read without reacquiring NFC. Continue and selfie capture have no write side
effects. An admitted write may complete after navigation is withdrawn, but cannot
publish a result into that retired flow.
Restoration creates a new selfie attempt, marks the reference as historical, and
keeps the original read time and local verification provenance. Session reset clears
active evidence; the separate delete action owns persistent erasure and fences
in-flight saves. Startup may complete only an already durable erase request.

App Attest and the Pulse server chain are deferred. Neither stored local checks nor
restoration imply server verification, fresh chip possession, Android wizard parity
or measured recognition accuracy. Delivery and acceptance status is recorded in
[HANDOFF.md](../../HANDOFF.md).

### A.8 Durable verification workflow: call chain and implementation contract

**Status: implemented in the working tree; physical qualification pending,
2026-10-21.** Source validation, signed installation and device acceptance have
separate receipts. This section supersedes A.7's in-memory-only lifetime for retained
verification evidence. Session cancellation still withdraws acquisition and UI
publication; it does not erase committed evidence. Explicit deletion owns erasure.

#### Ownership and execution order

`PassportFaceJourneyController` owns the journey and its durable workflow identity.
Capability controllers own capture and inference; hosts bind platform lifecycle,
permission adapters and service ports. Renderers only display supplied state and
emit typed intents. `PassportCaptureStore` remains the app's repository adapter;
`KenshikiProtectedStorage` owns encryption, key custody, connections and erasure.
Reuse `KenshikiMotion` and its Pulse sample/summary conventions rather than creating
a competing sensor algorithm. A workflow recorder owns the session-wide witness;
the selfie receipt binds its own capture-specific evidence to that timeline.

The required call chain is:

```text
Begin or resume workflow
  -> commit workflow identity, generation and start/resume event
  -> request motion and when-in-use location permissions in the workflow
  -> journal acquisition, permission changes, interactions and sensor windows
  -> MRZ capture -> commit MRZ checkpoint
  -> NFC read -> local checks -> commit NFC evidence and each check outcome
  -> read back admitted passport reference -> display passport result
  -> selfie capture + TrueDepth + capture-time sensor/location bindings
  -> commit selfie and receipt -> display selfie review
  -> Compare intent -> commit attempt and immutable input references
  -> read stored input -> Aura inference -> commit Aura outcome
  -> read stored input + the exact committed Aura outcome
  -> Liquid capture-quality pass -> validate -> commit outcome
  -> Liquid comparison/age-context pass -> validate -> commit outcome
  -> Liquid presentation/environment pass -> validate -> commit outcome
  -> assemble result from committed outcomes -> display/export
```

Each arrow crossing storage requires an acknowledged commit before the dependent
action is admitted. An inference call never runs inside a SQLite transaction.
Completed local checks and failed/unavailable checks are separate observations;
persisting a failed read must not admit its portrait as authenticated. Restored
passport evidence retains its original capture time and verification provenance.
A new session does not turn historical NFC evidence into a fresh chip read.

#### Durable records and transaction boundaries

| Record | Required content and binding | Commit boundary |
| --- | --- | --- |
| Workflow | Stable ID, storage generation, schema version, lifecycle and start/end events | Before acquisition; append lifecycle transitions durably |
| MRZ | Exact accepted fields, source/capture identity and original observation time | At accepted optical/manual MRZ, independently of NFC success |
| NFC | Original DG/SOD/portrait bytes, hashes, MRZ reference, local check results and trust-bundle identity | Before admitting the portrait or publishing successful read completion |
| Selfie | Original encoded image, image hash, capture ID, admission receipt, TrueDepth evidence and linked sensor/location records | Before review becomes available; no dependency on tapping Compare or Done |
| Interaction/sensor | Workflow and segment IDs, ordered sequence, action, sample windows, permission state, clocks and explicit gaps | Bounded periodic batches; flush and acknowledge the boundary event before admitting a dependent CTA |
| Model attempt | Immutable input references/hashes, predecessor attempt ID, model/profile/preprocessing identities, state and timing | Commit pending attempt before inference; atomically commit its outcome afterward |
| Liquid pass | Pass ID, exact input manifest/prompt/schema digests, decoder parameters, completion reason, token/resource diagnostics and parsed outcome | One transaction per pass; retry appends an attempt |

The installed version-1 passport schema must migrate transactionally with its
records preserved. Unreleased prototype migrations can change until validated;
once installed, migration identifiers and checksums are immutable. Forward or
unknown schemas, invalid checksums, broken foreign keys, source substitutions,
missing keys and partial records fail closed without replacing the database.
Schema changes, migration history and `user_version` advance in one transaction.

SQLite is the source of truth. A downstream stage reconstructs inputs from
committed records, verifies bindings, then releases database connections before
running. Passing the previous callback's object directly to Liquid does not satisfy
this contract. Immutable attempt identities prevent retry from overwriting an
older successful or failed result. Atomic completion updates the attempt outcome
and its workflow link together. Interrupted pending attempts remain discoverable;
recovery records interruption and admits an explicit retry instead of inventing a
completion. Write acknowledgements lost after commit are resolved by idempotent
readback of the same record ID and content digest.

All records have explicit encoded-size and retention bounds. Capacity exhaustion
is a visible storage failure, not silent eviction. Deletion covers the workflow,
its evidence, model inputs/results, sensor/location records and associated export
artifacts according to the shared erase inventory. Generation fencing prevents
old tasks from writing into a replacement store. In-memory state may cache a
bounded working set, but cannot be the only copy of an accepted stage.

#### Motion, interactions, location and provenance

Motion spans MRZ capture, NFC handling, selfie capture, navigation and model-result
interaction while the workflow is active. Record semantic action codes, such as
confirmation, retry, retake and cancellation, with wall time and monotonic time;
never journal entered identity text or credentials as interaction telemetry.
Record attempted and admitted transitions separately where storage gates admission.

The initial recorder uses the existing 50 Hz, 300-sample/five-second bounded
motion witness. Drain windows at a bounded cadence (initial target one second),
commit raw samples with the Pulse summary, and retain a durable high-water mark so
overlapping snapshots cannot double-count samples. Reconcile summaries against
their retained samples. Capture bindings reference the exact relevant interval,
not whichever window happens to be newest when inference begins.

Periodic collection cannot promise zero loss under abrupt termination. Record the
last durable sample and any undrained interval as unknown after recovery. Buffer
limits, permission denial, sensor unavailability, queue pressure, suspension and
clock discontinuity must be explicit. Stop sensors on background/cancellation and
begin a new segment on resume; never interpolate across a gap or a reboot. CTA
admission waits for its bounded flush, while Stop/Cancel remains responsive and
can leave a recorded interruption instead of trapping the user behind storage.

Request Core Location when-in-use access; no background entitlement is required
by this workflow. Persist the actual permission/accuracy authorization, fix time,
observation time, latitude/longitude, horizontal accuracy, available altitude and
vertical accuracy, plus source information exposed by the OS. Capture-to-fix
association records time delta and freshness policy. Missing, stale, approximate,
denied and unavailable fixes remain distinct; never substitute zero coordinates.
Capture may proceed with explicitly unavailable location unless a separately
reviewed policy requires it.

The canonical location observation is stored in SQLite and bound to the capture's
exact original bytes/hash. EXIF may carry a copy where our image encoder supports
it. EXIF is mutable metadata and cannot establish authenticity. Hashes detect
changes relative to a trusted record; they do not prove that location or pixels
were genuine at acquisition. Motion, TrueDepth and interaction signals support
an assessment of physical device handling; none independently proves a human
holder, absence of injection, liveness or complete identity acceptance. App Attest
and the authenticated server chain remain deferred, with their absence explicit.

#### Discrete Liquid passes and resource lifetime

Each pass receives only its task's images, committed context, response schema and
relevant example. It may read a prior pass only by an explicit predecessor binding.
Keep Aura context visible, including its score meaning and source hashes. Quality,
visible comparison/age context, and presentation/environment observations have
separate schemas and failure states. Each pass can complete, fail, be unavailable
or be interrupted independently; the UI retains successful passes after another
fails. No pass can turn a cosine observation into a calibrated match probability.

Depth, blink and motion summaries must appear as supplied measurements in the
model input. Absence of a video sequence must not be represented as absence of
sensor evidence. A still image cannot support temporal visual observations;
temporal findings require retained, ordered frame evidence. Preserve real DOB
provenance and century ambiguity, and distinguish current claimed age from age
when the document portrait was taken. Examples cannot supply facts about the
current holder. Unsupported or contradictory outputs receive a typed validation
failure while retaining bounded diagnostic evidence.

The versioned profile fixes per-pass input/output token limits, image dimensions,
decoder settings, schema enforcement capability, cache ceiling, stage deadline
and cancellation behavior. Profile changes receive a new identity/digest. The
implementation must distinguish EOS, token limit, deadline, cancellation, invalid
JSON, schema failure and contextual inconsistency; a generic response error is
insufficient. Persist structured token/time diagnostics and bounded raw output
in protected storage so failures can be inspected off-device.

Run one model operation at a time. Release Aura inference resources before
admitting Liquid; keep at most one Liquid model session and reuse it across passes
only within the measured memory budget. Release image tensors/KV state between
passes and unload model resources after completion, interruption or memory
pressure. A timeout must cancel and await actual engine settlement before a retry
or another model call; racing a timer against inference is not resource cleanup.
No unbounded retry, concurrent duplicate inference or timer-triggered model reload
is allowed. Establish concrete profile limits using SHF peak/residual-memory and
latency measurements; smaller prompts alone do not establish a memory fix.

#### Delivery order and acceptance evidence

1. Finalize versioned records, migration and repository API; exercise migration
   from the installed passport database and partial-write/reopen failure cases.
2. Wire MRZ and selfie admission to independent durable checkpoints. Wire Aura
   completion and Liquid input to committed readback, including explicit resume.
3. Add the workflow recorder, CTA/lifecycle hooks, raw motion persistence, location
   adapter and capture bindings. Surface recording status, gaps and stored evidence
   in details/export without exposing identity data in operational logs.
4. Split Liquid into the discrete passes, correct supplied-context semantics,
   version the profiles and preserve pass-level results/diagnostics. Apply measured
   resource limits and settle cancellation before reuse.
5. Run adversarial repository/controller tests and affected native/guard lanes.
   Build/sign/install on SHF only after validation, then verify database readback,
   interrupted-workflow recovery, useful output and measured memory behavior.

Required adversarial cases include version-1 migration rollback on every DDL
boundary; unknown/corrupt schema refusal; disk-full/key-unavailable commits; lost
commit acknowledgements; process death between every stage; repeated CTA input;
cross-workflow/cross-image Aura substitution; stale model completion after erase;
duplicate/out-of-order/overlapping sensor windows; permission changes; stale and
missing fixes; reboot/clock discontinuity; token exhaustion; malformed and
contextually contradictory model output; timeout with an engine still running;
and reopening a failed Liquid pass without rescanning the passport or selfie.

Source tests, iOS compilation, encrypted database readback, signed installation,
physical recovery behavior and device memory measurements are separate receipts.
The active goal is complete only when the implemented call chain and these
affected checks agree. Existing installation or a database file's presence alone
does not establish that the required rows were committed or consumed.

Implementation checkpoint, 2026-10-21: the working tree saves MRZ independently
of NFC, gates selfie review on its commit, saves Aura before Liquid readback, and
records bounded workflow motion, interaction and authorized location events.
Stored results open without acquisition/inference. The primary app uses the v3
quality, comparison and presentation passes, each with a pending input descriptor
and immutable terminal outcome in schema version 3. Partial results stay visibly
processing; completed matching passes are reused on retry. The model is released
before relinquishing the shared inference lease. A settled Aura outcome is
committed and read back before cancellation withdraws its return to the caller.
Stage writes require an existing database and cannot recreate erased storage.
Deletion also retires the workflow journal, awaits its active write, discards
failed retries, and starts the next workflow with a fresh queue and watermark.
Native tests and installation receipts remain distinct from pending physical
database readback, recovery acceptance and memory profiling on SHF.

### A.9 Liquid v4 repair and physical qualification

**Status: authorized implementation in progress, 2026-10-21.** The device v3
baseline reached a result without a process restart, but quality repeated its
synthetic prompt example verbatim and comparison/presentation hit their 25-second
deadlines. Neither failure exhausted its output-token allowance. The aggregate
incorrectly reported completion. These findings invalidate useful-assessment
acceptance for that run; persisted evidence and a well-formed response alone do
not establish that the model examined the images.

The implementation divides ownership between SDK contracts, runtime resources,
and app storage/orchestration. Freeze their shared types before integration.
The integrator owns manifests, package/API inventories, native checks and device
qualification; a separate review follows implementation. Preserve the v3
contract and migration digests as historical evidence.

The v4 call chain is committed capture, committed comparison-time snapshot,
committed Aura readback, then quality, comparison, age, presentation and sensor
consistency tasks. Each task retains its pending/terminal transaction boundary.
Image selection is explicit: quality/comparison/age receive the image pair,
presentation receives the whole selfie, and sensor consistency receives the
measurements without redundant image encoding. The pinned runtime must support
the text-only route; absence of images is not absence of retained capture evidence.

The full canonical evidence context and compact model projection are separately
retained and hashed. Projection may remove opaque digests, reduce numeric display
precision, and select bounded summaries, but never changes the stored original
measurements. Bind projection, media order, prompt, output schema, model artifact
and profile to each attempt. Preserve Aura context and documentary DOB ambiguity;
do not substitute document issue date for portrait date. Scene-specific synthetic
worked outputs do not enter the live prompt. Example reuse and unsupported facts
must not become accepted observations merely because JSON validation succeeds.

Freeze the workflow snapshot through the acknowledged Compare interaction,
separately from the immutable selfie-capture boundary. A snapshot is scoped to
one operation, workflow, image pair and event boundary, survives process death,
and is reused on retry. Do not extend it implicitly with events that occur during
inference. Full later sensor events remain available in the independent workflow
archive. Historical results without this boundary remain historical; no fabricated
interaction or silently refreshed snapshot may make them appear current.
For a historical capture, recover the first committed Compare boundary after
that exact capture and before a retake; later idle activity is excluded. If the
original boundary is unavailable, superseded or exceeds the declared capacity,
retain a verified explicit workflow limitation while keeping capture-time
measurements. Storage I/O, corruption and key failures remain fatal errors and
cannot be relabeled as missing historical telemetry.

Schema v4 must expand the v3 pass constraint and persist comparison snapshots.
Keep the original v3 SQL and migration checksum intact. Apply a transactional
replacement/copy with exact payload/checksum preservation, validation and rollback
on every failure boundary. Preserve v3 result decoding, distinguish profile and
payload versions, and prevent v3 successes from satisfying v4 attempts.

The runtime records model setup, image preparation, grammar preparation, prefill,
generation and cleanup wall times plus token and allocator diagnostics on both
success and failure. A bounded model setup and whole-chain deadline accompany
per-task limits. Cache only immutable preparation that is safe across requests;
every generation has fresh constraint state and source-bound input/KV state.
Timeout and cancellation await actual native/GPU settlement before resource reuse.
Allocator peaks are not total process footprints or proof of released memory.

The aggregate state is processing, completed, partial, failed or cancelled with
explicit per-task counts. All required tasks must succeed for completed. UI and
export consume the same prepared state, display individual diagnostics, and offer
selective retry without redoing successful matching tasks or acquisition.

Acceptance requires adversarial tests for example contamination, mixed/all-failed
aggregates, changed projection/media order, cross-snapshot and cross-image inputs,
migration fault injection, duplicate/lost commit acknowledgements, interruption,
erasure and late completions. Native compilation and tests precede installation.
Use the same retained capture for device benchmarks, attach before inference,
record task and whole-chain latency, process peak and post-run residual memory,
and verify recovery/readback. Additional tasks or smaller prompts alone are not
evidence of lower latency or memory use. App Attest/server verification remain
deferred under the local-check scope in A.8.

### A.10 Call-chain lifecycle audit

**Status: local repair and adversarial validation; SHF memory qualification remains
pending, 2026-10-21.** Direct retrieval of the device's 13:23:26 crash report
identified a main-thread Swift assertion in `KenshikiCopy.text`, called while
expanding comparison telemetry. The v4 diagnostic vocabulary included missing
localization keys. Those keys and scoped unknown-diagnostic handling are repaired;
global localization assertions remain strict. This identifies that crash's
assertion path, not a measured end-to-end memory lifecycle. Memory ownership and
peak/residual qualification remain separate.

Each comparison controller invocation has a separate generation from the durable
operation ID. Restoring the same operation must not admit a retired invocation's
progress or completion, including detached callbacks and reentrant UI callbacks.
The inference scheduler removes canceled queued requests without waiting for
active native work. Active work retains its lease until settlement; cancellation
must never permit overlapping models.

Pass history is authenticated within one SQLite read transaction. Capture,
snapshot and each distinct Aura record are validated once for that operation;
every pass still has its own payload, metadata, transition and descriptor checks.
No validated snapshot cache survives the operation or connection. Append checks
reserve capacity for outstanding pending attempts' terminal records.

The recorder persists every admitted sensor window, but the journey only
invalidates its evidence-status display when the status changes. Expanding
details or receiving actual model progress remains a presentation update; a
one-second sensor heartbeat must not reconstruct all visible telemetry views.

The coordinator attempts model release exactly once on each exit and retains
both the original operation failure and a subsequent cleanup failure. A cleanup
failure cannot turn into a successful chain. Model weights remain resident across
passes; temporary request tensors and grammar state do not. Whole-process memory
also includes Swift evidence objects, image decoding and UIKit allocations.
MLX allocator snapshots, taken before every outer Swift scope exits, cannot prove
that those objects were released. Token and wall limits are checked at cooperative
boundaries; a running native preparation/kernel is awaited rather than forcibly
abandoned. Neither limit is a hard operating-system execution bound.

Required physical evidence remains: a trace covering model load, all five passes,
details expansion, completion and idle; stable repeated retry cycles; and crash
termination diagnostics. Preserve the stored capture and distinguish allocation
churn, retained-object growth and an operating-system memory-pressure termination.

### A.11 Direct developer retrieval of comparison diagnostics

Debug device builds provide an explicit file request/response handoff rather than
requiring report copy/paste. A foreground-only worker reads
`Library/Caches/KenshikiDiagnostics/request.json`, accepting only version 1,
a UUID request ID and an optional UUID operation ID. It never accepts caller paths
or opens a network listener. Requests are bounded to 4 KiB and expire after five
minutes; duplicate requests cannot rerun an export within that worker.

The export acquires the inference scheduler's lease before reading committed
capture, Aura, Liquid attempts and the comparison snapshot. It does not load a
model or invoke acquisition. The same pure report formatter supplies UI copy and
the exported report. Export completion is distinct from assessment completion;
orphan pending attempts are reported as requiring reconciliation, never as proof
that inference is active. The source records are unchanged.

`response.json` is an atomic, complete-file-protected, backup-excluded export
capped at 4 MiB. It includes original capture telemetry and individual pass inputs,
outputs and diagnostics, but excludes portrait/selfie bytes, encryption keys and
the full raw workflow archive. The snapshot manifest and workflow summary remain
available. Document DOB and current-age candidate fields are removed recursively
from exported `inputContext` and `modelInput`; age-pass results remain present.
The disclosure marker identifies redacted inputs. Original input hashes continue
to bind the unredacted durable records, rather than the exported projections.
The response expires after five minutes on a foreground polling tick.
The worker uses the journey's existing store and owner lifecycle. It does not
create an independent store handle whose epoch becomes stale after deletion.
Debug deletion shares the export lease so completed export writes settle before
the store and export files are erased. Polling stops on foreground withdrawal.

The developer command `scripts/pull_reference_diagnostics.py` sends a fresh
request and retrieves its matching response through the app-data-container file
service. Stale request IDs cannot satisfy a new request. Host outputs are private
files outside the repository. The canonical SQLCipher database and its
device-bound key remain on the device. This developer mechanism is excluded from
release builds; it does not add server verification or change inference policy.

### A.12 Liquid runtime retirement, 22 October 2026

The experimental `BiometricVisualAssessment` SDK product, Liquid/MLX runtime,
model provisioning and reference-app inference orchestration are retired. The
reference journey executes AuraFace against source-bound persisted inputs.
Existing capture/motion acquisition, protected storage, snapshots, MRZ admission
and recovery remain in force. Passive historical visual-record readers belong
to the app's `LegacyVisualArchive` source group, not an SDK capability; they
must not load prompts/models, schedule inference or depend on MLX. Historical
wire meanings, hashes, migration validation and erase inventories are preserved.
Older Liquid implementation descriptions in this appendix are historical context,
not an active runtime requirement. Live presentation must not display retired
model output as a current result. Native and physical evidence remain separate.

### A.13 Reference-app start and saved-work navigation, 22 October 2026

The start screen has one primary action for a new passport/selfie comparison.
Saved passport reuse, comparison readback and unfinished chip reads belong to a
separate Saved work destination. Developer examples and recording status belong
to Developer tools. Idle recording status and saved capture timestamps do not
appear on the start screen. Deletion is reached through Saved work and requires
an explicit confirmation; cancellation retains every saved record.

`PassportFaceJourneyController` owns these destinations and deletion admission.
The host prepares localized navigation, content links and actions; the common
renderer only places and emits them. Navigation between these destinations does
not start acquisition or inference. Existing storage, recovery, original-byte
bindings and foreground admission remain unchanged. Home, saved-work and
confirmation layouts need native tests, large-text/RTL review and separate
physical acceptance; screenshots do not establish assistive-technology acceptance.

### A.14 Stable live selfie presentation, 22 October 2026

A readiness update must retain the live preview view, its parent, and its geometry.
The renderer updates supplied labels and button state without reattaching the
camera surface. Guidance sits below the preview and reserves the space required
by its localized alternatives, including large text; guide layer updates have no
implicit animation. Capture readiness and all evidence admission remain owned by
the existing SDK/controller.

The host coalesces a changed visual instruction for 250 ms. Losing readiness
immediately disables the shutter and withdraws a displayed Ready instruction;
regaining the manual shutter requires the current instruction to settle. Timers
are fenced on state changes, withdrawal and foreground loss. This is presentation
scheduling, not a change to frame freshness, depth, blink or automatic capture
requirements. A real-camera physical acceptance run remains separate from
synthetic churn/layout tests.

### A.15 Results, workflow motion and Pulse passport verification, 22 October 2026

The reference result keeps Done as its sole fixed primary action. The result shows
passport-check status and the exact unthresholded similarity observation. A native
action menu holds retake/retry and opens a second-level details sheet. Technical
provenance and the explicit Copy report action belong in that sheet; closing it
returns focus to the result. Sensor heartbeats must not rebuild the open details
screen or reset its reading position.

The motion projection reads acknowledged persisted events from the whole workflow
through a recorded review boundary, including MRZ/NFC and selfie retakes. It shows
minimum/maximum ranges for recorded axes, magnitudes and numeric window summaries.
Permission states, missing magnetic evidence, measured gaps and separate recording
segments remain explicit. Resume intervals are not continuous coverage. The raw
samples and capture receipt retain their original bytes; the projection grants no
identity or liveness verdict. Closing details, replacing a session or beginning a
retry fences pending projections.

Fresh reference-app passport reads compose the established Pulse registration,
attested session, nonce, terminal Chip Authentication relay and verification wire.
The app registers its own key and installation with the production App Attest
application identifier; it never borrows Pulse credentials. Shared foundation owns
canonical JSON, registration custody, signing serialization and attestation retry.
The optional host adapter retains source provenance in
`reference-apps/passport-server-provenance.json`. Headless SDKs remain independent
of this optional service composition. Missing configuration or a failed server
check cannot silently become a locally verified server result.

The nonce-derived eight-byte Active Authentication challenge and exact DG14
terminal relay reach the existing reader. The verification submission excludes
DG2/portrait bytes and binds the exact payload to App Attest. Returned session and
nonce identities must match the request. Saved server observations bind the SOD
and original verification time; reusing them remains historical. CoreNFC shows
actual bounded authentication/data-group percentages and chip-transport completion,
separately from subsequent passive authentication and the server verdict.

Source checks, synthetic protocol/controller tests, native builds and signed SHF
installation are distinct evidence. Physical NFC/AA/CA/server acceptance and full
VoiceOver qualification require their own current-device observations.

### A.16 Continuous reference MRZ acquisition, 23 October 2026

The reference host consumes continuous `NativeMRZSession.onFrame` candidates,
following Pulse's app-owned `MRZCapture` delivery. Its complete-read parser still
requires complete, unambiguous TD3 fields and valid check digits; durable commit
and explicit confirmation still precede NFC. The optional SDK `onReady` guide and
temporal contract remains unchanged for other consumers. Frame callbacks are
fenced against stopped and replacement acquisitions.

`PassportMRZCapture` adopts the existing identity SDK virtual-first camera policy
and native automatic constituent switching, baseline zoom clamp and continuous
focus/exposure. Source and test provenance pin the donor revision and exact files.
No Document capability dependency or new public API is introduced. Accurate,
full-frame Vision OCR settings are unchanged. Bounded camera diagnostics contain
only fixed lens vocabulary and native scalar settings; reviewed sink hashes and
adversarial guard tests reject identifiers, OCR payloads and extra log sinks.
Native tests and signed installation remain separate from physical MRZ/NFC speed,
focus and complete journey acceptance.

### A.17 Complete Pulse passport adoption and shared repair, 23 October 2026

**Status: source audit reconciled; implementation and qualification in progress.**
The owner requires the complete working Pulse NFC → ICAO service → bound return
implementation. A matching proof shape or successful scan does not establish
session, recovery, custody or presentation parity. Proven bad mechanisms are
repaired in both Pulse's actual dependency path and the reference path.

The authoritative path is Pulse's identity-spine preparation controller/reducer
and coordinator, its called identity SDK/Gateway and supplier reader, the deployed
Worker contract, and the post-read custody/presentation. Full source identities,
active call edges, deliberate differences and required executed tests accompany
adoption. Connect/Bond/Vouch authorization and remote face completion remain
separate product ceremonies; the selected local AuraFace path stays unthresholded.
No stored or displayed local result becomes a server identity acceptance decision.

#### One owner for the optional Pulse service

A named optional `KenshikiPulsePassport` product under `services/pulse/` owns the
Pulse-specific registration/session/nonce/CA/verify contracts, bounded transport,
typed Worker failures, prepared-ceremony lifecycle and credential mutation owner.
Both the Pulse/legacy Gateway path and reference app delegate to that product.
Legacy compatibility adapters map existing public types without recreating wire
requests or retry policies. Existing face/Vouch DTO boundaries must not create a
new SDK dependency on the predecessor identity product.

This product reuses foundation's canonical JSON, registered-key custody, assertion
sequencing and protected-storage mechanisms. Pulse-specific HTTP codes, endpoints,
DTOs and retry policies do not enter foundation or neutral capability modules.
A new generic framework is not justified merely because two apps consume the same
Pulse adapter. Passport, biometric and document remain independently consumable.

Hosts own reviewed-document admission, camera/NFC invocation, UI and their
retention profile. They do not own an independent session/registration algorithm.
Every new target/export/source/resource and public compatibility adapter receives
manifest, boundary, API, CI and adversarial guard coverage in the same change.

Pulse's actual Gateway, direct continuity clients and copies of those clients
share the same retained credential owner. Existing injected transports and
reviewed nonreserved headers retain their contract. Host erasure barriers lease
credential mutations across their awaited work; erasure closes admission,
invalidates old clients, cancels and drains old flights, then clears custody.
The existing installation DELETE remains bound to the exact retained identity;
failure preserves custody and a stale completion cannot erase a replacement.
Fresh enrollment after the completed erasure uses a new generation.

Existing Bond-issued nonce submission uses the same verified-read acceptance
construction without creating a new standalone session or coercing its workflow
and payload commitment. This preserves the existing Bond continuation; it does
not add Bond, Vouch or face endpoint writes to the reference flow. Private holder
use requires the current retained installation/origin as well as the exact SOD.
Identity rotation retires that private use while preserving truthful historical
public reports. A host cannot substitute a same-report verification token from
another accepted read.

#### Required complete sequence and invariants

| Stage | Required shared behavior / source precedent | Qualification |
| --- | --- | --- |
| Installation | Modern registered-key custody with distinct app namespaces; exact bundle identity for recovery; one semantic ensure/recover/dead-key mutation owner | Actual Worker-shaped identity/recovery vectors, accepted-response loss, expired bearer, concurrent mutation, invalid-key and unrelated-error negatives |
| Preparation | Reuse Pulse's complete attempt (operation ID + issued time), generation fencing and live ceremony; exact bounded conflict/expiry/stale-time rotations | Port complete reducer/controller/classifier suites and execute against both consumers |
| Assertion | Same timestamp and identity in canonical signed session request; exact DeviceCheck invalid-key recovery once, never blanket key rotation | Actual signed-byte fixtures, cancellation at every await, rejected stale identity/attempt and unsupported-platform tests |
| Reader | Same requested groups, PACE/BAC selection, nonce-derived AA challenge and remote CA last; one owned task/session through invalidation and release | Production APDU peer tests, parent-read cancellation across terminal await, stale session/tag and repeated loss/reposition vectors |
| Untrusted chip bytes | Bounded nested DG cursors, exact supported MRZ lengths, facial/JP2 record bounds, AA framing/ownership and empty signing-certificate refusal | Actual malformed production-parser and independent AA/DES positive/negative vectors; no trap, fabricated success or cipher/policy rewrite |
| Local admission | Passive authentication after transport closure, exact original portrait/SOD lineage, authenticated DG1 names, reviewed-page correspondence BEFORE remote submission | True mismatch produces zero verify requests; signed-DG1 tamper refused, DG11 expansion accepted without fuzzy matching, original DG2/portrait preserved |
| Remote verification | Same exact allowed proof, attested canonical bytes, issued session/nonce binding, current trust/CRL and required AA/CA policy; dispatched nonce retired conservatively | Actual Worker contract fixtures and missing/contradictory proof, expiry, replay, response-loss and binding negatives |
| Custody | Actual server report and private holder capability bound to origin, installation and exact SOD; transactional protected save before accepted result | Historical missing facts remain unknown, token absent from every export/log/display, source substitution and interrupted/failed save tests |
| Presentation | Pulse's issuer/root, signed-data and server-proof semantics; actual returned report; optional unperformed mechanisms do not become failure rows | Both passport result and journey L2 use one prepared projection; precise recovery actions, locales, scale and lifecycle tests |
| Continuation | Accepted persisted passport leads to selected local selfie/Aura flow; retake/cancel/store generations remain fenced | Whole native ceremony → checkpoint → portrait/selfie/result test; separate real-device and assistive-technology evidence |

The service must not update remote installation facts for a printed/chip association
already refused locally. A possibly consumed nonce is never offered to another
scan. Cancel/positioning retries reuse only a still-live unconsumed ceremony.
Delivery retires a challenge before local proof construction/admission can fail,
including cancellation immediately after delivery; pre-delivery positioning
cancellation retains it. Host diagnostic callbacks are reentry boundaries and
cannot resurrect a retired generation.
Storage can retain explicitly local evidence without authorizing a verified result;
local and server custody facts remain separate. Reference SQLCipher protection,
strict transport/response binding and modern one-time key custody are preserved.

#### Repair both dependency paths

The current Pulse reader resolves through the predecessor identity SDK. During
this extraction, both that supplier tree and `passport/third-party/` must receive
the same reviewed runtime repairs, including earlier destination-only security
fixes. Exact mirrored runtime hashes and attributed provenance prevent unnoticed
drift; upstream origin hashes are retained. A future single distribution boundary
is separate from silently changing a package identity during this repair.

Both paths retain supported legacy ICAO compatibility. Bounds/ownership fixes do
not replace cryptographic algorithms or broaden trust coverage. Published trust
material and deployed service JavaScript do not change without a separately
reviewed, authorized release. Actual AA/CA hardware availability is recorded;
a passive-only passport cannot qualify physical AA/CA interoperability.

#### Integration, review and release

Implementation ownership separates the shared service, reader repairs and host
composition. Interfaces freeze before parallel consumers change. An independent
review checks every audited state/edge against its destination and executed
regression. All unexplained differences remain open, rather than disappearing
behind an aggregate test count.

Run both predecessor/monorepo passport harnesses, affected shared-product native
lanes, legacy Gateway compatibility, Pulse app preparation/custody tests and the
reference whole journey. Require exact-source no-skip required-test receipts,
current-head hosted checks including Sonar, separate API compatibility review,
and immutable signed artifacts. Install only the integrated qualified reference
artifact on SHF, then verify the physical flow. Merge/synchronize main/dev and
prune only contained inactive branches after those gates; preserve concurrent
work and unfinished branches. No source/build/install receipt substitutes for
physical acceptance or permission to publish unrelated production code.

### A.18 Mobile-reusable frame selection, 23 October 2026

The owner authorized a shared native face-selection stack, prioritizing an actual
passing iOS build. The first milestone implements the
[frame selection contract](../../contracts/face-frame-selection-v1.md) in the
biometric capability: a dependency-free C++ selector, a thin Swift interface in
the existing optional inference product, and owned matcher preparation reused by
selected-frame comparison. macOS and iOS consume the same implementation. No
passport-similarity value enters selection; no new identity threshold or PAD
decision is introduced.

The external Mac workbench is the first real-input adopter. It preserves the
original encoded frame, OFIQ raster and runtime provenance, evaluates actual
matcher preparation before selection, retains every exclusion, and compares the
exact selected prepared owner. Historical quality-only replay reports remain
unchanged. Shared snapshots and guards cover the additive unpublished API;
independent C++/Swift tests, iOS device/simulator compilation and simulator test
execution are separate evidence requirements.

OFIQ assessment remains a distinct integration gate. The measured external 1.0.3
binary is macOS-only and uses a different ORT runtime from the SDK's reviewed
Apple artifact. The full profile has nine model files totaling about 434 MB on
disk; this is not a measured memory requirement. Before an iOS assessor is
introduced, qualify one compatible process runtime, OpenCV/device/simulator
artifacts, immutable config/model loading, allocation/thread/lifecycle behavior,
licences/provenance and representative-device resource limits. Do not substitute
upstream's newer wrapper or present a selector build as mobile OFIQ execution.

The existing iOS capture coordinator's first-admitted-frame behavior and its
frame/depth/motion admission receipts remain unchanged in this milestone. A
future bounded capture window must retain the exact receipt for each candidate;
it cannot attach the latest receipt to an earlier selected image. Android
bindings, mobile OFIQ execution, ranking calibration, app installation and
physical capture acceptance remain individually qualified delivery steps.

### A.19 Local phone quality selection workflow, 23 October 2026

The owner requested the actual phone workflow and installation on SHF. The
[selection contract](../../contracts/face-frame-selection-v1.md) now describes
bounded original-frame acquisition, per-frame receipts, optional local OFIQ
assessment, actual matcher preparation, shared native selection, protected
lineage persistence and exact prepared-owner comparison. Controllers own this
behavior; renderers only display localized state and dispatch typed events.

The separate optional `biometric/quality-apple` package exports `BiometricQuality`
and keeps its source-built local binary outside the main SwiftPM graph. Even a
product not selected by an adopter can force local binary resolution in SwiftPM;
placing it in the main package would break primitive-only consumption. A narrow
`BiometricRuntime` product re-exports the parent's existing pinned binary, so the
sidecar does not redeclare ORT or depend on matcher behavior. Its native framework is built from
pinned OFIQ/OpenCV sources with reviewed platform/lifetime changes. It resolves
against the existing pinned Apple ORT artifact, with serial CPU execution; no
second runtime or model weights are carried in the framework. The asset helper
verifies every exact profile file before the signed app is qualified for SHF.
Compile-only CI without those assets must never be reported as runtime acceptance.

Capture, quality, preparation and comparison preserve distinct source/raster/
aligned/model/policy identities. The highest native UQS policy is uncalibrated;
it adds neither passport-similarity optimization nor a recognition/PAD threshold.
Cancellation fences publication and waits for native work to settle before the
next model owner starts. Model weights, original media, build artifacts containing
weights and private evaluation records stay outside the source tree. Fresh
native builds, actual test execution, runtime parity/resource measurements,
installation and physical acceptance require separate receipts. Android binding
and production qualification are separate work, not implied by an Apple build.

### iOS document capture extraction — 2026-10-23

The first DL restoration step moves the existing document implementation into `document/`
with its tests and source/native provenance. `DocumentSDK`, `DocumentCaptureApple`,
`DocumentCapturePreview`, `DocumentCaptureJournal` and `DocumentCapture` separate portable
contracts, native acquisition/processing, preview, temporal recording and workflow orchestration.
OpenCV remains the reviewed existing implementation. No Regula adapter or resource returns.

Generic capture custody is exported from shared foundation and reuses protected storage and
evidence-manifest mechanisms. Foundation stores opaque revisioned workflow bytes; document
owns typed front/back/portrait selection validation. The public erasure-intent operation keeps
durable revocation before native settlement. No second SQLCipher/key/attestation engine is
copied into a capability. Host-supplied native proof adapters remain separate from optical
processing; a native sample may demonstrate the public in-memory optical path without an
identity backend or synthetic production proof.

The package graph, exact source and binary trees, native provenance, public API surfaces,
required test identities, source/dependency/artifact freshness and crash evidence are guarded.
Private retained-corpus replay is explicit and fails without its external inputs; it is not
counted as public qualification. Android processing, complete authenticity/identity policy,
physical and accessibility acceptance, package publication, and Pulse/SSA/reference-app
cutovers remain separate. Existing app inputs and donor records are retained until those
reviewed cutovers. Execution receipts and remaining limits belong in the document ledger.

### SDK app optical document integration and navigation — 2026-10-24

The native SDK app starts with visible capability tabs. The enrollment-style
Passport → Selfie journey is not the startup route or a prerequisite for reaching
Document, Passport or Face. Explicit debug launches retain its regression coverage.

The iOS Document tab composes the public document camera/preview, preparation,
OCR/PDF417 and face-region extraction APIs. A controller owns explicit admission,
front/back review, retakes, generation fencing and serialized camera retirement;
the renderer receives prepared state. No camera starts merely from launching the
app or selecting a tab. Images and observations are in memory and clear on reset,
page withdrawal or backgrounding. This is optical acquisition/processing, without
durable custody, issuing-state verification or an identity-acceptance verdict.

The app integration baseline preserves the source snapshot of the currently
installed face-quality build. The document package and app resolve the same root
foundation package; tests have capability-specific target names so all three
capabilities can coexist. Source, compilation, simulator integration, installation,
physical acquisition, accessibility and final acceptance remain separate evidence.

### Canonical native front capture — 2026-10-25

The reusable front controller lives in `DocumentCaptureApple`; its optional UIKit
surface and advisory level projection live in `DocumentCapturePreview`. The
controller composes the existing native camera, adaptive controls, observation
freshness and automatic-capture coordinator. Manual capture keeps explicit
operator-initiated admission; automatic capture carries the triggering observation
identity into native admission. Gravity display does not authorize a photograph.

The reference Document tab is the first consumer, through a forwarding adapter.
Its front surface remains mounted during guidance changes and image processing.
Product copy and theme remain generated from the shared JSONC design resources.
This replaces the reference app's separate front acquisition composition. Pulse
and SSA adoption are subsequent bounded cutovers; their predecessor implementations
remain until those consumers are changed and tested. Optical review still has no
durable-custody or identity-verification requirement.

### SDK app document capture persistence — 2026-10-25

The next bounded reference-app milestone saves each reviewed optical side before
advancing, using the existing shared protected SQLite mechanism. A named shared
Secure Enclave signer binds the exact original, native acquisition metadata,
prepared image, extraction observations and portrait lineage under the existing
evidence manifest contract. Hosts select namespaces and scope; no remote
registration, supplier comparison or sensor-authenticity verdict follows.

Explicit saved-capture recovery restores authenticated historical bytes without
starting a camera or rerunning processing. Leaving/backgrounding and session reset
clear memory while preserving committed work. Confirmed document deletion owns its
separate store lifecycle. Save/read failure, interruption, stale completion and
erasure remain typed and fenced. Source, native tests, device compilation,
installation and physical save/relaunch acceptance remain separate evidence.

### Transactional document evidence — 2026-10-25

The stored originals are inputs for subsequent authenticity analysis, portrait
extraction, front OCR, PDF417 decoding and comparison of the front observations
with the barcode. Each processing stage retains its exact inputs, method/version,
outputs and signed evidence references. Future stages may journal pending rows;
completion requires one atomic publication of the exact required record set.
Interrupted or failed work remains incomplete. No partial set may appear as a
completed processing result.

The first bounded increment adds front-motion evidence to the existing capture
checkpoint. The SDK retains actual sensor callbacks, acquisition identity,
measured clock correlations and explicit issues/omissions. Collection bounds
remain recorded; a retained bounded segment does not establish continuous
coverage or exposure alignment. Back motion remains uncollected in this increment.

Document-side publication commits the snapshot, bound descriptor, independently
signed motion record, complete signature/reference set and current revision
pointer in one SQLite transaction. A paired snapshot reuses the committed front
motion record. Readback verifies the entire declared set before publishing it to
review. Failure preserves the prior revision. Existing snapshots and signatures
remain byte-preserved during the additive schema migration; absent historical
motion remains absent. An optical checkpoint records its completed acquisition
and processing scope; authenticity and front/barcode comparison results remain
separate future stages.

### A.20 Shared Sensors foundation — 26 October 2026

The owner authorized an independently consumable Sensors SDK product within this
monorepo, under `foundation/sensors/`. The first increment reuses the audited Pulse
clock, window, distribution and processed/raw acceleration reducer mechanisms and
their meaningful conformance tests. The [reuse map](telemetry-audit/README.md)
records source identities, existing integrations and the bounded investigation.

The shared [measurement/window contract](../../contracts/sensor-measurement-window-v1.md)
separates native measurements, platform-fused signals and derived observations;
declares units/gravity, frames/transforms, clock domains/correlation uncertainty,
sample/window identities, coverage, omissions, raw custody and all-input derivative
bindings. Existing `KenshikiMotion` APIs, numerical definitions and hash bytes remain
unchanged. New input-admission safety changes carry explicit provenance and tests;
valid-input mathematics is not silently replaced during extraction.

The first native package targets Swift/macOS/iOS and has no capability, service,
storage or UI dependency. Its nested Swift package supports independent local
consumption. Remote distribution, Android bindings and other sensor adapters are
separate delivery work. No workflow migration, replacement collector, calibrated
liveness threshold, model implementation or product acceptance policy is included.
Workflow lifecycle and retention stay host-owned; capability adapters retain exact
capture bindings; authoritative identity acceptance stays server-owned.

Closed inventories, source attribution, adversarial guards, compiler API snapshots
and explicit macOS/iOS device/simulator CI lanes accompany this product. Executed
conformance, native compilation and simulator execution receive separate receipts.
Installation, physical sensor behavior and liveness qualification remain separate.
The [persistent checklist](telemetry-audit-checklist.md) records current delivery and
verification rather than promoting source inspection into device acceptance.

### A.21 Private licence-check extraction — 26 October 2026

The [licence-check workspace](../../services/licence-check/README.md) implements
two independently consumable private ESM npm artifacts: the supplier-neutral
`@kenshiki-labs/licence-check` core and its optional
`@kenshiki-labs/licence-check-trusona` adapter. Both are version `0.0.0` extraction
artifacts with emitted JavaScript and TypeScript declarations. The adapter pins
the exact core version and uses its public package entry point. Packed consumers
need neither a sibling source checkout nor a TypeScript runtime loader. Registry
publication and release policy remain separately scoped.

This bounded extraction preserves `pulse.dldv.v1`, profile `trusona-dldv-2` and
`pulse-dldv-03-05-street-observation-1`, with pinned supplier/Pulse contracts and
synthetic vectors retained in the workspace's provenance. The core supplies
contract types, required-check calculation and the existing subject-binding
policy over already admitted, validated data. It is not host request admission
or complete identity acceptance. The pinned policy retains the first-street-line
mismatch observation, incomplete evaluation and supplier's unqualified status.

Package qualification on Node 22.22.2 executed 165 tests, including 66 pinned
synthetic Trusona vectors and actual loopback HTTP integration. Separate offline
tarball consumers executed public JavaScript exports and compiled against emitted
declarations; independent adversarial probes retained unchanged source hashes.
These records establish their package/transport scope, not live-provider behavior,
jurisdiction coverage, retention, accuracy, PAD or supplier qualification.

Public routes, authentication/authority adapters, operation/replay/spend storage,
customer configuration and deployment hosts, Persona, Pulse adoption and app
migration are outside this increment. Hosts retain admission, issuer/coverage,
disclosure, association and concurrency policy, the original deadline and
phone-only persistence obligations. No supplier fallback or create retry is added.
The broader licence-service roadmap remains separate from these private artifacts.

The [canonical consolidation checkpoint](telemetry-audit-checklist.md#canonical-consolidation-checkpoint--2026-10-26)
records merge and preservation provenance. The clean canonical baseline passed
the existing repository guard suite; expanded licence package inventories and CI
coverage are a subsequent qualification step, recorded only when executed on their
resulting revision. No publication, service deployment, vendor qualification or
physical acceptance is implied by package checks or branch parity.

## Appendix B. Enforcement correspondence and review record

| Requirement group | Current enforcement / source precedent | Required extension |
| --- | --- | --- |
| MOD/CON/QA | Identity SDK `Gates/boundary_gates.py`; capability wrappers and adversarial tests | Cross-foundation/capability graph and contract fixtures as modules are extracted |
| UI/DS/L10N/A11Y | Existing reference JSONC generator and neutral-source bans are precedents | Native generators, view AST/source-sink guards, full criterion matrix and native/manual acceptance |
| STORE/KEY/ATTEST/BFF | Existing identity implementations and source-backed inventory in SPEC-IDBIO-200 | Reusable foundation, Android implementations and real composed-flow/platform receipts |
| CI/EVID | Capability workflows and local guard/native/API entry points | Per-native-lane structured receipts and verified remote required-check configuration |
| FACE/NIST | Face workbench toolchain/sample receipts and pinned official references | Selected model, C++ adapter, official validation and actual evaluation |

This revision was developed with separate security/BFF, presentation/accessibility and QA/CI reviews. Reviewers were collaborating engineering agents, not independent laboratories or accessibility certification bodies. Their findings informed the contracts and concrete guard corrections; implementation evidence remains attached to the relevant repository and lane.

Revision 0.2 changes repository topology and governing-document location. It preserves the 71 normative requirement identities and does not claim model selection, foundation extraction, native UI implementation or external evaluation. The root workflow executes every capability in all five lanes; local and hosted results are recorded separately.
