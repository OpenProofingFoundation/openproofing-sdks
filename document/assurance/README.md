# Retained document replay

This optional package exercises production document processing against externally retained
pixels and manifests. Its inputs remain outside Git. It is separate from the required
public synthetic suite and the pinned public-domain Vision positive control.

Set `IDENTITY_EVIDENCE_GEOMETRY_REPLAY_MANIFEST` and
`IDENTITY_EVIDENCE_GEOMETRY_REPLAY_OUTPUT` for the geometry replay, and optionally
`IDENTITY_EVIDENCE_GEOMETRY_REPLAY_SCENARIO` to `v1`, `v2` or `v2-restoration`.
Set `IDENTITY_EVIDENCE_ID1_REPLAY` to a retained export containing its index, manifest,
and original pixels for the ID-1 replay. Invoke the selected test explicitly with
`swift test --package-path document/assurance --filter TEST_NAME`.

Missing or malformed inputs fail. The harness has no disabled or skipped qualification.
A passing replay does not establish physical capture, document authenticity or identity.
