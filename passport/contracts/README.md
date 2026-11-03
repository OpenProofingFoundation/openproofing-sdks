# Passport contracts

`PassportCheckOutcome` uses the same six check outcomes in Swift and Kotlin: `pass`, `fail`, `inconclusive`, `unavailable`, `unsupported`, `not_performed`. A check observation is not a final identity verdict. These outcome types are the only implemented capability surface in this scaffold.

Planned contracts must independently identify MRZ parse/check-digit results; BAC/PACE access and secure messaging; passive authentication and signer/trust-path validation; AA and CA; trust-bundle version/digest; consumed EF.SOD and DG1/DG2 digests and algorithm identifiers; supported algorithms; explicit missing/unsupported/failed states; interruption/cancellation and retry. An absent chip anti-cloning mechanism cannot become a success. MRZ check digits detect transcription errors, not issuer authenticity.

A portrait may be described as authenticated only after complete DG2 verification using the algorithm selected by EF.SOD and verified extraction lineage. Export exact consumed portrait bytes/digest, original authenticated group/source digest, encoding/dimensions, orientation/crop/transform identity and extraction version. Bind session/attempt/capture identity in composition. The capability must not claim server trust from a hash of an unverified client report.

Trust-material acquisition, signer chains, validity/revocation and stale-bundle behavior must be explicit. Generic source/portrait and service-port contracts are shared with the biometric/document capabilities without vendor DTOs or product wire formats. Shared fixtures must cover negative cryptographic/binding/unsupported paths before implementation is accepted. No final wire schema is implied by this scaffold.
