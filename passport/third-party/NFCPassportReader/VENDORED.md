# NFCPassportReader integration

Upstream: [AndyQ/NFCPassportReader](https://github.com/AndyQ/NFCPassportReader),
release `2.3.1`. The vendored package is `ThirdParty/NFCPassportReader` and requires
at least iOS 15. Preserve its upstream license, copyright notices, and packaged
`PrivacyInfo.xcprivacy` when updating it.

## Session ownership

`PassportReader` owns one CoreNFC session. It reserves its single-use instance
before changing read state. Availability or session-construction failure releases
that reservation because no session became live. Concurrent reads are refused.

`NFCReadSettlement` separates recording the first terminal outcome from releasing
the waiting caller. The continuation is armed before `session.begin()`. Success,
reader failure, and task cancellation record their outcomes before invalidating
the exact session. Only that session's invalidation callback releases the caller;
a later callback cannot overwrite the winning outcome.

Each detected tag receives a fresh `PassportTagAttemptState`: passport model,
protocol handlers, current group, and mutable read queue. Transient physical tag
loss discards the attempt and restarts polling on the same live session. Session
termination and task cancellation escape protocol fallback. Generation and session
identity checks prevent work from an obsolete tag attempt settling a current read.

## Authentication and transport

- `TagReader` uses one APDU exchange path for CoreNFC and the synthetic transport.
  Only status `9000` succeeds after secure-message unwrapping. Response continuation
  is bounded by fragment count and total bytes; cancellation prevents further sends.
- PACE selects a supported ECDH Generic Mapping entry from CardAccess. Unsupported
  mapping modes and domain parameters are refused before authentication dispatch.
  Nonces must occupy a positive number of cipher blocks. Mapping and ephemeral
  points must be valid; reflected ephemeral keys and malformed or mismatched
  authentication tokens are refused before installing secure messaging.
- BAC authenticates the encrypted reply and checks both exchanged nonces before
  deriving and installing a session channel. Malformed challenges, replies, or
  uninitialized key state cannot complete authentication.
- PACE failures retain a closed stage, reason category, and optional APDU status
  word. File selection and file reading have separate stages. These diagnostics
  do not contain MRZ data, cryptographic material, or chip payloads.
- Authentication-source logging is restricted by
  `scripts/assurance/pace-logging-guard.py`. The only permitted dynamic observation
  is the closed settlement source and whether it won.

## Reading and verification

`readPassportUnverified` reads the requested groups and closes CoreNFC before
returning `UnverifiedPassportRead`. Its caller must perform passive authentication.
`readPassport` invokes verification after that same transport operation returns.
The SDK's `IdentityEvidencePassport` adapter also verifies after session closure,
keeping certificate and signature work outside the NFC timeout budget.

Active Authentication runs only when the model exposes support. A configured
remote Chip Authentication terminal receives DG14 after all other NFC work. It
owns the replacement channel keys; the reader relays its protected command and
retains the chip response without claiming that the terminal's check succeeded.
Protected-group recovery guards queue removal so repeated refusals cannot remove
an element from an empty queue.

## Verification and updates

The dedicated iOS simulator harness in `Tests/PACETransportTests` exercises the
production transport, PACE, and BAC code with synthetic inputs:

```sh
bash scripts/assurance/run-pace-harness.sh
```

See `scripts/assurance/pace-harness/README.md` for prerequisites and the distinction
between synthetic consistency checks and physical interoperability. The
`Passport authentication` CI workflow runs this harness and the logging guard.

Session settlement and tag lifecycle tests also reside in
`Packages/IdentityEvidencePassport/Tests/IdentityEvidencePassportTests/`.
CoreNFC-dependent tests require an iOS test destination; a macOS-only test run
does not execute those paths.

For an upstream update:

1. Compare the upstream release with the complete vendored directory, including
   session ownership, authentication validation, transport, diagnostics, and the
   remote terminal interface described above.
2. Preserve or re-establish each invariant and run the simulator harness and
   passport lifecycle tests against the updated source.
3. Build the production iOS consumer and verify physical passport completion,
   cancellation, and transient tag-loss recovery.
4. Update the upstream version and integration description together with the
   package manifest's provenance comment.

## OSS passport port patches

The 19 October 2026 portrait repair recognizes JPEG's SOI/marker prefix without
requiring an APP0/JFIF segment. EXIF and other valid initial segments no longer
discard the original chip portrait. End-marker refusal and original-byte/DG2
preservation remain in place. Generated JPEGs exercise the actual DG2 parser and
ImageIO decoding; no real document images are test fixtures.

This copy carries the complete reviewed identity-SDK supplier tree and original patch history.
`passport/Gates/extraction-sources.json` in the monorepo records every donor and destination
file digest, source revision, local transformation and retained limitation. The source/destination
registry is authoritative for this port; the inherited `import-manifest.json` remains the historical
Pulse-to-identity import record and is not a claim that this new destination is byte-identical.

Three explicitly attributed changes accompany the OSS port:

- `Package.swift` fixes OpenSSL to the donor-resolved revision
  `71dbe0b4514cdaad95961470db72e8231f5943a6` (3.3.3001).
- `SecureMessaging.swift` verifies the truncated **computed** AES/DES response MAC,
  rather than truncating the supplied MAC on the AES path. It bounds protected-response
  TLV access, requires exact DO99/DO8E framing and rejects malformed encrypted padding.
- `Utils.swift` throws on empty/truncated supported BER-length encodings before indexing.

The port tests exercise actual production secure messaging with valid AES/DES responses,
forged MACs and malformed/truncated response framing. These focused safety patches do not
establish comprehensive hostile-input hardening of every inherited DG, ASN1 or AA parser.
Original supplier notices and the privacy manifest remain present; no private passport fixtures,
trust anchors, credentials or model assets were copied.

The 23 October 2026 parser/ownership repair validates the outer data-group BER
tag/length/body bounds before subclass dispatch, including valid two- and
three-byte opaque TLVs. `ChipAuthenticationPublicKeyInfo` now releases exactly
the owned `d2i_PUBKEY` reference when the Swift owner is destroyed; callers keep
borrowing the same key. Adversarial short-envelope tests and an OpenSSL ex-data
destructor observer cover the fixes, including an independently retained key
reference. No protocol bytes, cipher/hash selection or key material changed.

## Coordinated Pulse/reference reader repair (23 October 2026)

The same reviewed runtime repair is applied to Pulse's actual
`kenshiki-identity-sdk/ThirdParty/NFCPassportReader` dependency and the monorepo
`passport/third-party/NFCPassportReader` copy. Historical upstream/import revisions
remain unchanged in the provenance records. The monorepo's coordinated source
check compares the current runtime bytes; a matching copy alone is not native or
physical interoperability evidence.

Nested DG cursors bound tags, lengths and values to the declared parent. DG1
accepts the supported 72/88/90-byte MRZ shapes before fixed-offset access. DG2
validates its image count, FAC header, declared record and first-face boundaries,
feature offsets and JP2 extended box length before slicing. Optional/incomplete
DG14 entries and an empty SOD certificate list fail without dereferencing absent
children or certificates. Original signed data-group bytes remain unchanged.

AA bounds OpenSSL signature buffers and releases borrowed RSA/EC references.
RSA requires the partial-recovery `6A` header and the ICAO-specified complete
trailer before comparing the recovered digest with the exact supplied nonce.
ICAO 9303-11 section 6.1.2.2 requires ISO9796-2 B.6/B.7 (raw RSA opening),
including signatures greater than half the modulus. Recommended B.4/B.5
compatibility is limited to an odd exponent and the smaller signature: only the
corresponding `n - J` representative with valid framing and digest is accepted.
ECDSA uses the fixed `R || S` width derived from the EC group order; zero-padding
both integers to a larger width cannot change the accepted wire format. Hash
selection remains the issuer/protocol selection; no supported cipher is replaced.
The model retains an attempted AA challenge even if the chip returns no signature;
the adapter refuses that failed attempt rather than projecting it as not performed.

The detected-tag task is retained, cancellation closes its owner, and the matching
CoreNFC invalidation callback drains it before releasing the recorded first
outcome. No lock is held over cancellation or an await. The configured remote
terminal must use bounded cancellation-aware transport, as Pulse's URLSession
transport does. A synthetic terminal which ignores cancellation must eventually
return before drain completes; this is not a claim of arbitrary-callback preemption.
AA remains before terminal CA; the terminal's protected command is last and its
exact raw response does not become a local CA success claim. TagReader checks
cancellation before and after a raw exchange so a late response cannot become proof.

Both adapters derive correspondence names from authenticated DG1, preserving
optional expanded DG11 bytes in the data-group archive. The name mismatch remains
an exact comparison of equivalent MRZ fields, and passive authentication is still
required before projection. Public synthetic signed CSCA/DSC/SOD fixtures test
truncation, real mismatch and changed-DG1 refusal; there is no production trust
expansion and no retained private signing key.

Production-path regression cases cover truncated/nested DG envelopes, facial
records, empty certificates/AA values, RSA B.6 and B.4 nonce binding, malformed
RSA framing with a correct digest, fixed ECDSA width, OpenSSL destructor ownership,
remote AES/TDEA terminal command ordering/key IDs/chaining, cancellation during a
terminal await and after a raw response, independent DES/AES MAC vectors and
invalid padding. Runtime tests run natively in both package paths. Synthetic
transport tests do not exercise live CoreNFC delegate timing or prove physical
passport interoperability; SHF completion, cancellation and RF-loss recovery remain
separate acceptance evidence.

Primary contracts:

- [ICAO Doc 9303 Part 11](https://www.icao.int/sites/default/files/publications/DocSeries/9303_p11_cons_en.pdf),
  sections 6.1.2.1–6.1.2.3 and Appendix F step 9: the eight-byte nonce, hash/trailer
  selection, required B.6 and recommended B.4, and `6A || M1 || H || T` framing.
- [BSI TR-03111 v2.10](https://www.bsi.bund.de/SharedDocs/Downloads/EN/BSI/Publications/TechGuidelines/TR03111/BSI-TR-03111_V-2-1_pdf.pdf?__blob=publicationFile&v=1),
  section 5.2.1: plain ECDSA has fixed width twice the group-order octet length.
- ISO/IEC 9796-2:2010, Annex B.4–B.7, pages 20–21 (primary ISO text
  [available mirror](https://previewnorm.com/iso/ISO%20IEC%209796-2-2010%20PDF.pdf)):
  B.6 preserves the full RSA result; B.4 chooses the smaller signature and B.5
  disambiguates the odd-exponent complementary representative.

The combined protected-access-channel/terminal-CA regression additionally exposed
an inherited CLA mask that erased General Authenticate command chaining. The
repair preserves only the existing input `0x10` chaining bit while retaining the
previous masking of all other class/channel bits: `0x0C | (CLA & 0x10)`. The MAC
covers the corrected header. [BSI TR-03110-3](https://www.bsi.bund.de/SharedDocs/Downloads/EN/BSI/Publications/TechGuidelines/TR03110/BSI_TR-03110_Part-3_V2-1.pdf?__blob=publicationFile&v=1),
sections B.10.2 and B.11, requires terminal chaining support and an omitted CLA
indicating secure messaging with authenticated header together with chaining.
A native negative control using the old mask fails on the `0x1C` header and its
independent expected MAC/body digest for both AES and TDEA access channels.

The combined fixture uses public fixed keys (`42` repeated 16 times for AES;
`0123456789abcdeffedcba9876543210` for two-key TDEA), initial eight-byte SSC zero,
and terminal key bytes `04 || 21*260` (AES CA, two GA segments) or `04 || 21*64`
(TDEA CA), key identifier 7. Python cryptography 49.0.0 independently assembles
CBC encrypted DO87, status DO99 and ISO9797-1 algorithm-3/CMAC DO8E responses with
ISO7816 padding, odd command and even response counters. The test stores SHA-256
of each complete protected command data field as its independent encryption/MAC
oracle. The AES GA replies contain encrypted `7C00`. Each forged response fails
MAC verification before clearing the access channel or relaying the terminal
command. Successful handshakes clear the access channel only at the transition,
relay the original raw terminal header/data/Le unmodified and last, and preserve
its exact response data/status without a local CA-success claim.

## Optional observation defaults

The default selection and CardAccess-stage closures intentionally do nothing when
a caller requests only file bytes. Supplied observers still report the actual
selection/read boundary. Nested comments document these optional defaults; they
change no executable behavior, API, APDU or authentication policy. The same
comments are retained in both maintained reader copies.
