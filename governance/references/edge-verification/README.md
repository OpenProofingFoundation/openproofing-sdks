# Edge verification specification

Read [SPEC-IDBIO-200.md](SPEC-IDBIO-200.md), revision 3.1. Section 1.2 distinguishes
existing source implementations, host tools and proposed replacement work. Requirements
and numeric targets are separate from demonstrated results.

The main specification defines the required two-SDK architecture in section 2.1 and
removal of both Regula and InsightFace in section 8.4. **Appendix B: Implementation and
Migration Plan** contains proposed repository layout, extraction, work packages,
sequencing, cutover, adopter validation, publication and AXON acquisition. Appendix A
retains the candidate wire protocol.
The [AXON candidate inventory](axon-candidates.json) records public dataset metadata and
unresolved commercial/model-redistribution permissions; it contains no biometric samples.

- [Revision audit and release evidence gaps](revision-audit.md)
- [Payload schema](contracts/payload.schema.json) and [iOS envelope schema](contracts/ios-envelope.schema.json)
- [Synthetic optical ID-1 example](fixtures/ios-id1-complete.example.json)
- [Synthetic passport example](fixtures/icao9303.example.json) and [mDL example](fixtures/mdl18013_5.example.json)
- [Executed document checks](validation-results.json) and [source provenance](revision-provenance.json)
- [Preserved v3.0 working draft](history/SPEC-IDBIO-200-v3.0.md) and [historical review](REVIEW.md)

The schemas and fixtures are proposed contracts. They are not exported SDK APIs, real
attestation/service receipts or proof of security performance. No production migration
or deployment follows from this document revision.

To rerun the offline consistency checks with the existing local Python dependencies:

```sh
python3 docs/edge-verification/validate_spec.py
```
