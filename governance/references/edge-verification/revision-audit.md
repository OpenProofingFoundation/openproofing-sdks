# Revision 3.1 audit and remaining release evidence

Date: 2026-10-16. This record accompanies [SPEC-IDBIO-200](SPEC-IDBIO-200.md).
It describes a document revision, three parallel domain reviews and a second integration
review. It is not an independent laboratory evaluation, legal opinion or release approval.

## Structural revision: implementation planning in Appendix B

At the owner's direction, three parallel reviewers checked the boundary between the
engineering specification and its delivery plan. The main document retains architecture,
built-versus-planned status, model/preprocessing and other open technical decisions,
responsibilities, protocol references and acceptance requirements. Section 2.1 now holds
the enduring face/document SDK dependency contracts; section 8.4 holds vendor-removal
acceptance and the required final state.

**Appendix B: Implementation and Migration Plan** contains proposed repository layout,
REMOVE-01 through REMOVE-10, dependencies, accountable implementation roles, concrete
removal surfaces, cutover/adopter/publication mechanics and AXON acquisition. Appendix A's
protocol content and the standalone schemas/fixtures are preserved. Moving planning does
not weaken the required removal of both vendors or make technical release gates optional.
Internal references and the reader guide were updated; document validation was rerun.
The source-inspection provenance remains unchanged because this is document restructuring,
not a refreshed production-source audit.

The final independent comparison confirmed Appendix A unchanged apart from its separator,
all ten REMOVE rows preserved except the updated B.4 reference, and prior main technical
subsections unchanged except the intended architecture promotion and section 8.4 split.
All 48 candidate checks passed. Generated-heading anchors, local file links, appendix
order, work-package placement and validation-report hashes were also checked successfully.

## Subsequent scope clarification: removal and open-source delivery

The owner clarified that the plan must deliver removal of Regula and InsightFace and
separately released open-source SDKs. Section 1.1 now makes that end state explicit;
Appendix B supplies REMOVE-01 through REMOVE-10, proposed face/document repositories with
iOS and Android packages, source/build/resource removal surfaces, adopter rebuilds,
public-release evidence and a definition of done. The capture reviewer independently
checked the integrated removal plan and found no remaining must-fix issue in that scope.
Optional research branches and NIST/mDL work are not blanket prerequisites unless a
declared release path or claim depends on them.

The owner confirmed the Axon Labs Kaggle dataset account. Public listing/API metadata
for seven relevant assets was inspected and recorded in [axon-candidates.json](axon-candidates.json).
The listings declare CC BY-NC 4.0; commercial use and resulting-model redistribution
permissions remain unapproved. This is metadata acquisition, not a download of biometric
collections, executable repositories or approved model weights. No repository was created,
code extracted, vendor removed or public release published during this document update.

## Change control

- The user supplied v3.0 and authorized this swarm revision. The original working draft,
  including the earlier provisional architecture edit, is preserved unchanged in
  [history/SPEC-IDBIO-200-v3.0.md](history/SPEC-IDBIO-200-v3.0.md).
- [REVIEW.md](REVIEW.md) and [review-checks.json](review-checks.json) remain the historical
  first-pass review and checks, not current specification validation. The historical
  checker now explicitly targets the preserved v3.0 snapshot.
- The current canonical file is [SPEC-IDBIO-200.md](SPEC-IDBIO-200.md), revision 3.1.
- No production source, existing policy defaults, SDK/server byte contract, installed app,
  provider configuration or deployment was changed. Existing unrelated working-tree edits
  were preserved. Source inspection is against the working tree, not HEAD alone.

## Swarm review and reconciliation

| Review responsibility | Work performed | Integration findings addressed |
| --- | --- | --- |
| Capture/Cadastral reviewer | Read spatial contract, native acquisition, tilt, card-pose/specular measurements, calibration and host tools; drafted sections 2–4; reread integrated specification and traced actual Regula adapter responsibilities | Added existing specular measurement/calibration contracts omitted by the first review; removed sensor-origin, gyro-depth, immunity and nominal-metrology overclaims; scoped optical branches by path; added the section 8.3 responsibility inventory, including secondary/ghost and export/recovery gaps |
| Biometrics/evaluation reviewer | Read current model/provenance and comparison contracts; verified upstream AdaFace/NIST references; drafted sections 5, 7–8; independently reread integrated specification | Preserved Pulse licence-note qualification; separated trained artifacts from architecture; corrected preprocessing/calibration and NIST scaffold claims; attributed historical receipts; removed unverified deployment wording |
| Protocol/credential reviewer | Read SDK/server request binding, phone subject policy, App Attest and passport paths; checked primary platform/credential references; drafted section 6 and appendix A; attacked candidate fixture invariants | Removed recursive COSE/App Attest construction; specified actual bindings, profile compatibility and retry semantics; identified synthetic-checker evidence-resolution and receipt-generation gaps; required safe integers and clarified optical checks cannot waive selfie admission |
| Integration author | Reconciled one normative document, capability matrix, machine schemas, synthetic fixtures and offline checks | Incorporated built-versus-plan steering; resolved cross-section/path contradictions; preserved baseline; added evidence graph, replay/readback and parser/encoding negative cases |

Reviewer roles above identify agent responsibilities, not independent professional or
certification sign-off. No reviewer claimed physical-device execution or live-provider
coverage. The release record must still name accountable humans and required independent
review/evaluation evidence for each applicable gate.

## Disposition of the first review

| Finding | Revision disposition | What remains unproven |
| --- | --- | --- |
| R1: phone rotation versus relative card tilt | Sections 3.5 and 4.2 distinguish projected guidance, planar-pose assumptions and phone/card motion; existing sweep code is recognized | Device/camera calibration, independent pose error and joint detection rates |
| R2: photometric/tremor assumptions | Sections 3.1–3.4 define acquisition and attacker-control contracts; speculative thresholds are candidates | Timing/exposure uncertainty, supported sampling, accessibility and attack/genuine performance |
| R3: retained temporal bandwidth | Section 3.2 distinguishes 2-fps durable pacing and unpaced ring/live analysis | New bounded high-cadence processing and replay integration |
| R4: nominal geometry | Section 4.2 separates source observations, nominal grids and independent measurement | Calibrated physical accuracy and uncertainty propagation |
| R5: centroids and alteration | Sections 4.3 and 5.3 preserve unmasked Cadastral evidence, revision/open-set policy and issuer/phone integration | Trained artifacts, coverage inventory and held-out alteration performance |
| R6: face artifact/calibration | Section 5 specifies rights/provenance, input/precision, restoration and calibrated route policy | Replacement weights, legal-scope approval, numerical/device parity and biometric operating point |
| R7: App Attest/COSE | Appendix A uses exact payload bytes plus detached native proof; arbitrary COSE and recursive payload removed | Candidate protocol implementation, registration/verification and cross-language/device proof receipts |
| R8: combined predicate/lineage | Appendix A and candidate schemas bind captures, reports, manifests, services and attempt state; example policy rejects missing/contradictory required checks | Approved release profiles, authenticated composite receipt adapters and actual server enforcement |
| R9: passport/mDL distinctions | Section 6 separates PA/AA/CA, SOD-selected algorithms and mDL profile/trust/item/device checks | Current live NFC qualification, selected mDL implementation and trust operations |
| R10: NIST and release claims | Sections 7–8 replace incomplete code with artifact/harness gates and qualify budgets/targets | Linux artifact, current harness, NIST execution/publication, installed size and whole-flow results |

The first review's NIST summary was too terse: the retrieved API/general PDFs and the
public status page must be read together, including announced effective dates. Section 7
now makes the actual submission-time requirements authoritative and distinguishes the
internal P99 target from external median requirements. A listed CPU/OS is not proof of a
successful submission. The first review also missed source implementations of card-pose
and specular measurement; section 1.2 and section 3.5 correct that inventory without
promoting measurements to validated fraud detection.

## What the offline validation proves

[validate_spec.py](validate_spec.py) checks both standalone Draft-07 schemas, fixture
structure, exact request-hash construction, selected synthetic evidence/receipt/attempt
bindings, path-specific missing/negative outcomes, safe integers, duplicate/nonfinite/
invalid-Unicode rejection, and exact authorized result-readback semantics. Negative cases
include substituted Cadastral/custody/admission digests, selfie/portrait/report substitution,
receipt subject/generation mismatch, stale/replayed challenges, wrong platform environment,
reordered counters and unexpected raw biometric fields. Synthetic chip/mDL cases still
require live selfie admission even when optical document checks are not applicable.

These are documentation-level consistency tests with fabricated trusted evidence and
proof results. The assertion bytes are deliberately not a real App Attest proof. They
do not implement certificate verification, real model inference, PAD, issuer/carrier
calls, an atomic database transaction, production input hardening or enrollment authority.
The example complete-signals predicate is explicitly a proposed test profile, not a silent
change to the checked-in phone policy. The fixture's display `payload` must equal the
parsed `payloadJson`; the verifier hashes the latter's exact UTF-8 bytes.

The integrated protocol reviewer independently reran the checker and re-attempted the
earlier evidence-hash and receipt-generation mutations. All were refused after correction;
the final checker exercises 48 cases. This is an independent agent consistency check,
not independent laboratory or production cryptographic verification.

Run:

```sh
python3 docs/edge-verification/validate_spec.py
```

Dependencies are the existing local Python `jsonschema` package. The historical geometry
counterexample also uses NumPy. No dependency installation or full SDK test/build is
needed for these document checks. [validation-results.json](validation-results.json)
records executed candidate cases and current schema/specification digests;
[revision-provenance.json](revision-provenance.json) pins the inspected local source
inventory and repository revisions. Neither record is a physical or independent result.

## Decisions and evidence still required before a path can ship

1. Assign accountable people to the roles in sections 4.5, 8.2 and A.6; approve supported
   issuer/revision/device/credential and provider-coverage profiles.
2. Acquire/train/license exact replacement artifacts and the required measured calibration
   records; approve actual data/weight/SDK-adopter rights and retention/disclosure scope.
3. Implement the selected mobile methods and candidate adapters, or document a separately
   reviewed use of the existing byte contracts. Candidate JSON does not establish an API.
4. Freeze thresholds, genuine-user and attack-rate bounds, test populations and sample
   plans before blind evaluation. The numeric design targets remain unachieved here.
5. Produce the runtime/device, adopter, physical capture, external-service and independent
   evaluation receipts required by the selected path. Record source, built artifact,
   installation and physical acceptance separately. Decide each vendor's removal separately.

Those are release evidence gates, not unfinished document edits disguised as completed
validation. The revised document can be reviewed honestly now; empirical effectiveness
and release approval remain explicit future work.
