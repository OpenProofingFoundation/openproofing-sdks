# Current SDK handoff

24 October 2026. Consolidate the recovered implementation onto canonical `dev`
and `main`, preserving the current shared Pulse service and strict-concurrency
fixes. Git history records the checkpoint commits; temporary checkouts are not
the delivery location.

The document package contains native iOS front/back acquisition, source-bound
preparation, OCR/PDF417, provisional portrait extraction, and optional protected
custody/recovery. The iOS reference app now opens with visible capability tabs
and explicit camera admission. Its document review keeps images in memory and
clears them on withdrawal or backgrounding. It does not return an authenticity
or identity-acceptance verdict. Android document processing and adopting-app
cutovers remain separate work.

Passport, shared Pulse ceremony, original chip-portrait comparison, protected
storage and face-selection work remain present. Storage startup can retry
construction instead of retaining permanently unavailable ports. Debug storage
diagnostics export bounded reason codes without retained identity contents.
The existing store namespace, application identity, keys and lifecycle are
preserved; no erase/reset is a storage-recovery step.

## Source and validation evidence

[The recovery record](governance/recovery/2026-10-24-source-recovery.json) retains
the original frozen hashes and identifies changed inputs. Exact recovery,
reconstruction and later lifecycle fixes are recorded separately from execution.
Donor and native supplier hashes remain attributed in the capability inventories.

Fresh qualification is recorded under `.build/validation/`,
`.build/presentation/`, `.build/document-capture/` and
`.build/foundation-validation/`. Require matching start/end input hashes,
the complete declared test identities, and successful process exits. Old receipts
or component-only tests do not qualify a changed full app. GitHub check runs,
including SonarCloud, remain a separate promotion checkpoint.

The full app, native package and shared-consumer checks must pass before the
canonical promotion is complete. Signed artifact, installation, physical
front/back capture and assistive-technology acceptance are separate evidence.
Simulator tests do not establish physical licence capture or resolution of the
reported on-device storage failure.

## Working checkout discipline

Use the primary `kenshiki-sdks` checkout and named, committed branches. Keep
temporary compilation outputs under ignored `.build/` or the external face
workbench. Before consolidation or cleanup, commit active source, preserve
unique refs in a verified Git bundle, and archive untracked source/receipts with
hashes. Remove a registered checkout through Git only after confirming it is
clean and its work is preserved. Keep unrelated active checkouts intact.

Architecture and delivery boundaries remain in
[APP-ARCH-001](governance/architecture/APP-ARCH-001.md).
