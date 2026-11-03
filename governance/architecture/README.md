# App and SDK architecture

[APP-ARCH-001](APP-ARCH-001.md) is the governing app/SDK architecture standard. It covers the document, passport and biometric independently consumable capability products in kenshiki-sdks, shared foundation products, native presentation, JSONC, i18n, accessibility, BFF authority, guards, QA, CI and evidence.

Biometric/document verification methods remain in SPEC-IDBIO-200. Implementation/adoption planning is Appendix A of APP-ARCH-001. Agent entry points reference the same standard.

[Foundational telemetry audit checklist](telemetry-audit-checklist.md) tracks the
source investigation, mathematical inventory and evidence needed for the shared
measurement/window contract, including Pulse sensor, fusion and BFF mechanisms.
Update its checkboxes and evidence record as audit work completes.

The [motion-first Sensors SDK reuse map](telemetry-audit/README.md) records the
existing Pulse implementation, SDK integration comparison, source provenance,
executed shared-package tests and the remaining contract decisions.

Run `python3 governance/architecture/validate_architecture.py` from the monorepo root for structural checks. [validation-results.json](validation-results.json) records the last executed document check. Domain review and implementation receipts remain separate.
