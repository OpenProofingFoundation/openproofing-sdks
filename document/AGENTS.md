# Repository guidance

Read README.md, contracts/README.md and docs/extraction-ledger.md before implementation. The frozen SPEC-IDBIO-200 snapshot in ../governance/references/edge-verification/ governs verification design; record its hash when updating provenance.

Keep iOS and Android in this capability directory. Public document APIs must be vendor-neutral and independent of the identity product, face matcher and paid backends. Preserve source/portrait coordinates and provenance. Hosts supply wording, policy identifiers and storage locations. Do not add raw identity documents, biometric data, credentials, proprietary models or vendor resources.

Record attribution and source hashes for extracted code. Preserve unrelated source-checkout edits. Distinguish scaffolding, implementation, native builds, integration and physical acceptance. Run the platform builds affected by a change; macOS compilation does not establish iOS compilation. No commit, remote creation, publication or deployment is implied by local implementation work.

Read docs/qa.md before extraction. Run npm run check and each affected native lane. Zero-debt guards have no baseline suppressions. Carry behavior tests, synthetic fixtures and relevant assurance harnesses with each extracted component; extend guards in the same change for new modules, languages, dependencies or assets. Public API snapshots require explicit compatibility/versioning review.

## Shared requirements

Follow [root guidance](../AGENTS.md) and [APP-ARCH-001 revision 0.2](../governance/architecture/APP-ARCH-001.md)
for renderer purity, JSONC/localization, accessibility, contracts, foundation/BFF
boundaries and QA/CI evidence. Those shared rules apply to every change here.
