# Open Proofing SDKs

Native software development kits for identity proofing on mobile devices: identity
document capture and reading, passport chip reading and verification, and biometric
portrait primitives, with the shared contracts and foundation they rely on.

This repository is published by the **Open Proofing Foundation**, a Washington
nonprofit corporation (a 501(c)(6) business league). See <https://openproofing.org>
and the Foundation's specifications at <https://openproofing.org/specifications>.
The code is kept in sync with Kenshiki Labs' development repository, where it
originates.

## What is here

| Area | Contents |
| --- | --- |
| [Document](/document/README.md) | iOS document capture, geometry, OCR and PDF417 reading, portrait observations |
| [Passport](/passport/README.md) | iOS MRZ parsing and capture, NFC chip reading, BAC/PACE, credential checks, chip portrait extraction |
| [Biometric](/biometric/README.md) | Swift, Kotlin and C++ portrait and embedding primitives; iOS TrueDepth acquisition |
| [Foundation](/foundation/README.md) | Shared Swift custody, protected SQLCipher storage, lifecycle fences and signed evidence manifests |
| [Contracts](/contracts/README.md) | Versioned schemas and conformance vectors |
| [Design system](/design-system/README.md), [Presentation](/presentation/README.md), [Reference apps](/reference-apps/README.md) | Optional native resources, demonstration controllers and example apps |

The SDKs are pre-release: every product is at version `0.0.0` and no packages have
been published. They return observations, not identity-acceptance verdicts; biometric
comparison has no calibrated match threshold. The full developer guide, including
build and validation commands and the implementation status of each area, is the
[repository README](/README.md).

## License

Licensed under either of the [Apache License, Version 2.0](/LICENSE-APACHE) or the
[MIT License](/LICENSE-MIT), at your option. Third-party components keep their own
licenses, recorded in the license and notice files that accompany them.

## Contributing

Contributions are welcome under the Developer Certificate of Origin; every commit needs
a `Signed-off-by` line (`git commit -s`). See [CONTRIBUTING.md](/CONTRIBUTING.md).

Everyone taking part follows the [Code of Conduct](/CODE_OF_CONDUCT.md). Report
security vulnerabilities privately as described in [SECURITY.md](/SECURITY.md), never in
a public issue.
