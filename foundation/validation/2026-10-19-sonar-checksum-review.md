# Protected-storage receipt checksum review

This review records three verified false positives. It authorizes no other
finding classifications and leaves the historical validation receipt intact.

The reviewed source revision is `da9f7e33b1aae54d5ebee9da11d187393aae96ff`.
The report is `foundation/validation/2026-10-18-protected-storage.json`.
Each finding uses rule `json:S6418` and identifies the word `Credential` in a
source filename under a `sourceSHA256` map:

| Issue | Report line | Receipt lane |
| --- | --- | --- |
| `AaFROpA5idhKYWVJzL94` | 31 | `root` |
| `AaFROpA5idhKYWVJzL95` | 110 | `ios-device` |
| `AaFROpA5idhKYWVJzL96` | 194 | `ios-simulator` |

The map key is the tracked source path
`foundation/Sources/KenshikiOperationBinding/CredentialLifecycleAdmission.swift`.
All three values are the same SHA-256 digest:

`c1ee67716f8e17f2397d2dda8fccb5881c7d67c9fe099dbce7bfedace4bea006`

Recomputing SHA-256 over that exact Git source blob produces that exact value:

```sh
git show da9f7e33b1aae54d5ebee9da11d187393aae96ff:foundation/Sources/KenshikiOperationBinding/CredentialLifecycleAdmission.swift | shasum -a 256
```

These are reproducible hashes of tracked source bytes. They are neither stored
credentials nor access tokens, private keys, or authentication material. The
matching word is part of a Swift source filename. The report and the hashed
source are unchanged by the attestation-retry pull request. The historical
receipt bytes and their hashes remain intact.

Independent source-hash verification was performed on 2026-10-19. The owner
explicitly approved these three exact classifications on that date, and the
coordinating agent confirmed their resulting `FALSE_POSITIVE` status. No other
finding was accepted or excluded by this review.
