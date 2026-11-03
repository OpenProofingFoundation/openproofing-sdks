# Kenshiki SDKs

Independent native document, passport and biometric SDKs, with shared contracts,
foundation products and optional native presentation.

The [foundational motion API guide](foundation/motion/README.md) describes shared
sensor collection, units, timing, derived features and passport/document/selfie
integrations, including current retention differences and unification gaps.

## Implemented scope

| Area | Implementation | Remaining scope |
| --- | --- | --- |
| [Document](document/README.md) | Extracted iOS capture, geometry, OCR/PDF417, portrait observations, temporal recording and source-bound recovery; shared custody; optional native sample | App cutovers, physical qualification, Android processing and document authentication |
| [Passport](passport/README.md) | iOS MRZ parsing/capture, NFC reader, BAC/PACE, credential checks and authenticated original portrait extraction | Android reader and broader physical/device qualification |
| [Biometric](biometric/README.md) | Swift/Kotlin/C++ portrait and embedding primitives; iOS TrueDepth acquisition; Apple Vision alignment and optional AuraFace CPU inference | Android acquisition/inference, complete derivation verification, calibrated recognition/PAD and FRTE algorithm adapter |
| [Foundation](foundation/README.md) | Swift sealed-operation custody, registered-key enrollment/retry, protected SQLCipher storage, lifecycle fences and signed evidence manifests | Product adapters, platform qualification and Android counterparts |
| [Sensors](foundation/sensors/README.md) | Independent local Swift measurement/window contracts and extracted Pulse timing/statistics/motion reducers | Capability migration, additional sensor adapters, remote distribution, Android and physical qualification |
| [Pulse service](services/pulse/README.md) | Optional shared passport ceremony, strict Worker wire, installation credential owner and bound validation reports | Exact signed-build and physical acceptance remain separate |
| [Contracts](contracts/README.md) | Versioned portrait, embedding, operation, receipt and evidence schemas with conformance vectors | Additional producer/derivation and product integration contracts |
| [Design system](design-system/README.md) | JSONC schemas/compiler, generated Swift/Kotlin resources, localization and layered Icon Composer artwork | Reviewed translations and full native accessibility acceptance |
| [Presentation](presentation/README.md) | Independent Swift/Kotlin demonstration controllers | Optional presentation remains separate from headless SDKs |
| [Reference apps](reference-apps/README.md) | iOS capability tabs with live document, passport and biometric examples; Android simulated examples | Physical capture/accessibility acceptance and Android live-flow parity |

The comparison returns a cosine observation. It has no calibrated identity-match
threshold or identity-acceptance verdict. Installation, automated tests, physical
acceptance and measured recognition performance are separate evidence.

## Develop and validate

Use the pins in `.node-version`, `.python-version`, the Swift manifests and Gradle
projects. Apple lanes require Xcode 26; Android requires JDK 17 and the SDK versions
in the corresponding project. The Android reference app pins Gradle 9.8.2 and AGP
9.4.1. Keep model weights, real identity media, private
indexes and machine-local environments outside Git.

```sh
bash scripts/python.sh -m venv .build/python
npm ci --ignore-scripts
npm run bootstrap
npm run check
bash scripts/python.sh scripts/check.py --sdk biometric --platform all
bash scripts/python.sh scripts/presentation_check.py --platform ios-ui
```

Install the exact Python version in `.python-version` first. `scripts/python.sh`
selects it without changing other repositories' Python installations. Run bootstrap
before validation, not concurrently with checks.

`--sdk` selects `document`, `passport`, `biometric` or `all`; native lanes include
`guards`, `macos`, `ios-device`, `ios-simulator`, `android` and biometric `nist`.
`npm run check:all` includes all SDK consumers and the applicable native reference,
capture and passport suites. See [QA and CI ownership](governance/monorepo.md).

Fresh scoped receipts live in `.build/validation/`, `.build/presentation/` and the
capability-specific build directories. Check source hashes, required test IDs,
skips and timestamps. Checked-in validation JSON records are dated evidence,
not a claim that the current checkout or hosted checks pass.

## Navigation and authority

- [HANDOFF.md](HANDOFF.md): current delivery checkpoint, blockers and next actions.
- [AGENTS.md](AGENTS.md): repository working rules; capability guidance adds local boundaries.
- [APP-ARCH-001](governance/architecture/APP-ARCH-001.md): governing architecture and implementation plan.
- [Model qualification](governance/model-selection.md): artifact roles, provenance and release requirements.
- [Research pack](governance/research/README.md): pinned primary methods and adoption notes.
- [Frozen references](governance/references/edge-verification/README.md): imported verification specification and provenance.

The root Swift package exports the shared foundation products. Each capability's
Swift and Android packages remain independently consumable. Source publication,
model/data rights, package releases and production deployment require their own
qualification; repository consolidation does not confer those permissions.
