# Hardware-bound store keys, version 1

`KenshikiProtectedStorage.HardwareBoundStoreKeyCustody` owns a separate random 256-bit
data-encryption key for each application/store/purpose/explicit-Keychain-group/access-policy identity. Store identities are
length-framed, hashed for the Keychain account, and authenticated by the wrapping envelope. Changing
an identity is a migration, not an alias or fallback. Evidence signing, App Attest and passkey keys
are distinct mechanisms and are never reused as database keys.

Production creation requires `SecureEnclave.isAvailable` and creates a
`SecureEnclave.P256.KeyAgreement.PrivateKey` with the `privateKeyUsage` constraint. There is no
software fallback. `identityWhenUnlocked` uses
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; `backgroundAfterFirstUnlock` uses
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Neither adds a biometric/user-presence prompt.
Both the enclave key's access control and its encompassing Keychain record use that policy. The
Keychain item disables synchronization and selects the Data Protection keychain. Every read, add
and delete selects the explicitly supplied `keychainAccessGroup`, and the group is authenticated in
the envelope identity. No query falls back to all entitled groups. Adopters supply the exact
resolved application-only group; an intentionally shared group is a different declared namespace
and does not establish app-only access. Entitlements and resolved artifact configuration require
separate validation.

The Keychain record contains the CryptoKit opaque enclave-key representation, a versioned identity,
an ephemeral public key, a public random 32-byte salt and an AES-GCM-wrapped data-encryption key. It
does not contain the raw data-encryption key. At wrapping time, an ephemeral P-256 agreement key
performs ECDH with the enclave recipient's public key. HKDF-SHA256 derives a 256-bit wrapping key
using the salt and domain-separated, length-framed identity plus both public keys. AES-256-GCM
encrypts the 32-byte data key with that same binding as authenticated data. Opening uses enclave
agreement with the ephemeral public key and repeats the derivation and authentication.

This is an application envelope composed from CryptoKit primitives, not a claim of HPKE protocol
conformance, FIPS validation, independent cryptographic certification or hardware-attested data
capture. The enclave private key stays hardware-bound; the recovered AES data key and plaintext
necessarily enter application RAM during SQLite or record use. Scoped temporary `Data` is cleared
on return as a best effort; Swift copies, CryptoKit internals and SQLite key schedules do not provide
a provable process-wide zeroization guarantee. Public APIs export no raw key; the SQLite key callback
and durable-erasure key removal are internal to the selected foundation product.

Record encryption uses AES-GCM and authenticates a separate versioned domain, full store identity,
record identifier and caller-supplied immutable context. This prevents moving a ciphertext to another
record or namespace. It does not alone prevent replay of an older valid ciphertext; the evidence
sequence/manifest authority and store erase-generation fence must reject rollback independently.

## Recovery, migration and deletion

* A Keychain lock/denial error is propagated. It is never treated as a missing key.
* Retained ciphertext with no Keychain record returns `missingKey`; it never generates a replacement.
* Invalid identity, malformed stored record, unknown version, hardware loss and authentication failure
  preserve the original Keychain record and ciphertext for recovery.
* Simultaneous creators use atomic `SecItemAdd`. A loser reloads and uses the persisted winner.
* `importLegacyKey` is an input-only bridge restricted to the registered `CustodyAdapter` SPI. The legacy adapter must verify that the supplied 32-byte
  key opens its retained evidence before import. An existing identical key makes import idempotent;
  an existing different key is refused. The adapter must retain the legacy key until reopening the
  original ciphertext through the new vault succeeds, then remove the legacy material durably.
  `migrateLegacyAESGCM` decrypts only an explicitly supplied legacy combined box with its original
  authenticated data, then returns a new record-bound envelope. It never creates/imports a key on
  missing custody. The adopting migration journal must recognize its old format and retire this
  transition; neither method authorizes an indefinite fallback to legacy key material after cutover.
* Reinstall can leave device-only Keychain records behind. With no retained ciphertext, the same
  namespace reuses that key; no new installation identity is inferred from it. Device migration that
  transfers ciphertext without the device-only key must report recovery unavailable, not data loss
  disguised as a clean store.
* Store erasure must fence publications, persist an intent, remove all ciphertext and sidecars, and
  only then remove the key. The store owns this lifecycle. A Keychain delete failure leaves erasure
  pending. The vault does not authorize server-account deletion or declare filesystem forensic erase.

## Validation boundary and primary API references

The local tests use an internal software-agreement fixture to exercise the real ECDH/HKDF/AES-GCM
codec, corruption, namespace/record substitution, missing/locked key adapters, import and creation
races. Test injection is not public production policy. Passing those tests does not qualify an actual
Secure Enclave or lock-state behavior. Device tests must exercise both protection profiles across
lock/unlock, first unlock after reboot, restart, key loss and controlled legacy migration before a
release can claim physical acceptance.

Apple API documentation reviewed 18 October 2026:

* [Secure Enclave key agreement private key](https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey)
* [Protecting keys with the Secure Enclave](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave)
* [After-first-unlock device-only Keychain protection](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)

The implementation uses the documented CryptoKit constructors and agreement primitive, rather than
exporting a Secure Enclave private key or running database cryptography inside the enclave.
