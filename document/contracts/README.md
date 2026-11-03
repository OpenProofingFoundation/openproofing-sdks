# Shared contracts

The initial shared vocabulary is `pass`, `fail`, `inconclusive`, `unavailable`, `unsupported`, `not_performed`. Swift and Kotlin expose these same strings. An individual check outcome is not an overall authenticity or identity verdict.

## Portrait handoff

The common [portrait/selfie v1 contract](../../contracts/portrait-selfie-v1.md) and synthetic conformance vectors are now specified. Production source/derivation and processing adapters must execute those vectors when implemented.

Extraction must preserve the existing source-to-portrait chain before freezing the public API:

- Original capture identity and digest, distinct from the portrait bytes' digest.
- Source dimensions, coordinate convention, orientation and any crop/warp/mask derivation.
- Portrait encoding, dimensions and exact artifact identity.
- Primary portrait selection and explicit absent/ambiguous/error states.
- Original versus restored derivative identity; restoration cannot silently replace the original.

The document package exports a generic source-bound portrait. The existing face system consumes it through an identity-product adapter. Neither public contract carries vendor-owned document types or requires the face package. Final wire shapes will be established against extracted code and shared synthetic fixtures, rather than duplicating the candidate composite identity envelope here.
