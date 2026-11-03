# Contributing

Thank you for your interest in the Open Proofing SDKs. This guide explains how to
report problems, propose changes and get a pull request accepted.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
Security vulnerabilities are never reported in public issues or pull requests; follow
the [security policy](SECURITY.md) instead.

## Before you start

This repository handles identity documents, passports and biometric data. Never put
real identity documents, photographs, chip data, biometric samples, phone numbers or
other personal data in an issue, a pull request, a test fixture or a log you attach.
Use synthetic data. Model weights, secrets and machine-local environments also stay
out of Git; the root guards reject unreviewed binary, model and image files.

## Issues

Open an issue to report a bug or propose a change. Include:

- the area affected (for example `document/`, `passport/`, `biometric/`,
  `foundation/`, `contracts/`, `design-system/`, `presentation/` or `reference-apps/`);
- the platform and toolchain (iOS, macOS or Android version, Xcode, JDK);
- the commit you are using;
- what you expected, what happened, and the smallest steps that reproduce it.

For a larger change, open an issue to discuss the approach before you write the code.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make one focused change. Add or update tests for the behaviour you change.
3. Run the checks described below for the areas you touched.
4. Sign off every commit (see [Developer Certificate of Origin](#developer-certificate-of-origin)).
5. Open a pull request against `main` and fill in the template.

The CI workflows in `.github/workflows/` come from the development repository and use
shared actions that are not public, so they do not run here yet; maintainers run the
checks below before a change is merged. A change that adds a new target, language,
asset, dependency or module also needs guard and CI coverage in the same change; if a
guard rejects a file you added, say so in the pull request and a maintainer will help.

If your change includes code you did not write, keep its original license and notice
files, record where it came from, and say so in the pull request.

### Relationship to Kenshiki Labs

This repository is kept in sync with Kenshiki Labs' development repository: changes
merged there are merged into `main` here. Keep pull requests small, and rebase onto
the latest `main` if a maintainer asks you to. Some documents in the repository, such
as `AGENTS.md` and `HANDOFF.md`, describe that development process (including its
own branch names); for contributions here, follow this guide.

## Build and check

The development setup is described in the [repository README](README.md#develop-and-validate).
In short:

- Use the pinned versions in `.node-version` and `.python-version` (install that exact
  Python version first), the Swift manifests and the Gradle projects.
- Apple lanes require Xcode 26. Android requires JDK 17 and the SDK versions in the
  corresponding project; the Android reference app pins Gradle 9.8.2 and AGP 9.4.1.

```sh
bash scripts/python.sh -m venv .build/python
npm ci --ignore-scripts
npm run bootstrap
npm run check
bash scripts/python.sh scripts/check.py --sdk biometric --platform all
bash scripts/python.sh scripts/presentation_check.py --platform ios-ui
```

Run `npm run bootstrap` before validation, not at the same time as checks.

- `npm run check` runs the root governance guards
  (`scripts/check.py --platform guards`).
- `scripts/check.py --sdk <sdk> --platform <lane>` runs native lanes. `--sdk` selects
  `document`, `passport`, `biometric` or `all`; lanes are `guards`, `macos`,
  `ios-device`, `ios-simulator`, `android` and, for `biometric`, `nist`.
- `npm run check:all` runs every lane for every SDK, with the reference, capture and
  passport suites.
- The licence-check packages in `services/licence-check/` have their own check: run
  `npm ci --ignore-scripts` and `npm run check` in that directory.

Logs and receipts are written under `.build/validation/` and `.build/presentation/`.
In the pull request, list the commands you ran and their results.

## Developer Certificate of Origin

Contributions are accepted under the Developer Certificate of Origin (DCO) 1.1. By
signing off a commit you certify the following
(from <https://developercertificate.org/>):

```text
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

Every commit in a pull request must carry a `Signed-off-by` line with your name and
the email address of the commit author:

```text
Signed-off-by: Your Name <you@example.com>
```

`git commit -s` adds it for you. To add a missing sign-off to your latest commit, run
`git commit --amend --no-edit -s`; for every commit on your branch, run
`git rebase --signoff main`, then force-push your branch. Commits without a sign-off
cannot be accepted.

## License

The code in this repository is licensed under either of

- the Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE)), or
- the MIT License ([LICENSE-MIT](LICENSE-MIT)),

at your option. Third-party components keep their own licenses; see the license and
notice files that accompany them.

Unless you explicitly state otherwise, any contribution intentionally submitted for
inclusion in this repository by you, as defined in the Apache-2.0 license, shall be
dual licensed as above, without any additional terms or conditions.

## About the Foundation

This repository is published by the [Open Proofing Foundation](https://openproofing.org).
Its specifications are at <https://openproofing.org/specifications>. For questions
that are not bugs or vulnerabilities, write to hello@openproofing.org.
