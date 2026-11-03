#if os(iOS)
import CoreNFC
import CryptoKit
import Foundation
import OpenSSL
import XCTest
@testable import NFCPassportReader

final class PassportActiveAuthenticationTests: XCTestCase {
    private let challenge: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]

    func testActualECDSAAAVerifiesIndependentCryptoKitSignatureAndRefusesMalformedProofs() throws {
        let key = P256.Signing.PrivateKey()
        let signature = Array(try key.signature(for: Data(challenge)).rawRepresentation)
        let model = ReaderProtocolFixture.ecModel(key: key)
        XCTAssertTrue(model.activeAuthenticationSupported)
        model.verifyActiveAuthentication(challenge: challenge, signature: signature)
        XCTAssertTrue(model.activeAuthenticationPassed)
        // Same mathematical r/s with an extra zero in each half must not be accepted.
        let overwide = [UInt8(0)] + Array(signature.prefix(32)) + [0] + Array(signature.suffix(32))
        for malformed in [[], Array(signature.dropLast()), signature + [0], overwide,
                          Array(repeating: 0xFF, count: 64)] {
            model.verifyActiveAuthentication(challenge: challenge, signature: malformed)
            XCTAssertFalse(model.activeAuthenticationPassed)
        }
        model.verifyActiveAuthentication(challenge: Array(repeating: 9, count: 8), signature: signature)
        XCTAssertFalse(model.activeAuthenticationPassed)
        let other = ReaderProtocolFixture.ecModel(key: P256.Signing.PrivateKey())
        other.verifyActiveAuthentication(challenge: challenge, signature: signature)
        XCTAssertFalse(other.activeAuthenticationPassed)
    }

    func testActualInternalAuthenticateUsesExactSuppliedChallengeAndVerifiesReturnedSignature() async throws {
        let key = P256.Signing.PrivateKey()
        let model = ReaderProtocolFixture.ecModel(key: key)
        let reader = PassportReader(tagAttemptLifecycle: ReaderProtocolFixture.lifecycle(model: model), aaChallenge: challenge)
        var commands: [UInt8] = []
        let transport = TagReader { command in
            commands.append(command.instructionCode)
            XCTAssertEqual(command.data, Data(self.challenge))
            return (try key.signature(for: Data(self.challenge)).rawRepresentation, 0x90, 0)
        }
        try await reader.doActiveAuthenticationIfNeccessary(tagReader: transport)
        XCTAssertEqual(commands, [0x88])
        XCTAssertEqual(model.activeAuthenticationChallenge, challenge)
        XCTAssertTrue(model.activeAuthenticationPassed)
    }

    func testActualRSAAAVerifiesImplicitAndExplicitTrailersAndRejectsWrongChallenge() throws {
        let key = try ReaderProtocolFixture.rsaKey()
        defer { EVP_PKEY_free(key) }
        let model = try ReaderProtocolFixture.rsaModel(key)
        for sha256 in [false, true] {
            let signature = try ReaderProtocolFixture.rsaSignature(key: key,
                recovered: ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128, sha256: sha256))
            model.verifyActiveAuthentication(challenge: challenge, signature: signature)
            XCTAssertTrue(model.activeAuthenticationPassed)
            model.verifyActiveAuthentication(challenge: Array(repeating: 9, count: 8), signature: signature)
            XCTAssertFalse(model.activeAuthenticationPassed)
            for malformed in [[], Array(signature.dropLast()), signature + [0], Array(repeating: 0xFF, count: 128)] {
                model.verifyActiveAuthentication(challenge: challenge, signature: malformed)
                XCTAssertFalse(model.activeAuthenticationPassed)
            }
        }
    }

    func testRSAB6AboveHalfModulusAndB4ComplementBothBindExactChallenge() throws {
        let key = try ReaderProtocolFixture.rsaKey()
        defer { EVP_PKEY_free(key) }
        let rsa = try XCTUnwrap(EVP_PKEY_get0_RSA(key))
        let modulus = try XCTUnwrap(RSA_get0_n(rsa))
        let half = try XCTUnwrap(BN_dup(modulus))
        defer { BN_free(half) }
        XCTAssertEqual(BN_rshift1(half, half), 1)
        var highSignature: [UInt8]?
        // Independently construct B.6 = F^d mod n; insist on > n/2 to distinguish B.4.
        for nonce in UInt8.min...UInt8.max {
            let recovered = ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128, messageByte: nonce)
            let candidate = try ReaderProtocolFixture.rsaSignature(key: key, recovered: recovered)
            let value = try XCTUnwrap(BN_bin2bn(candidate, Int32(candidate.count), nil))
            let aboveHalf = BN_cmp(value, half) > 0
            BN_free(value)
            if aboveHalf { highSignature = candidate; break }
        }
        let high = try XCTUnwrap(highSignature, "A B.6-only representative must be exercised")
        let value = try XCTUnwrap(BN_bin2bn(high, Int32(high.count), nil))
        defer { BN_free(value) }
        let low = try XCTUnwrap(BN_new())
        defer { BN_free(low) }
        XCTAssertEqual(BN_sub(low, modulus, value), 1)
        var lowSignature = Array(repeating: UInt8(0), count: high.count)
        XCTAssertEqual(BN_bn2binpad(low, &lowSignature, 128), 128)
        let model = try ReaderProtocolFixture.rsaModel(key)
        for signature in [high, lowSignature] {
            model.verifyActiveAuthentication(challenge: challenge, signature: signature)
            XCTAssertTrue(model.activeAuthenticationPassed)
            model.verifyActiveAuthentication(challenge: Array(repeating: 9, count: 8), signature: signature)
            XCTAssertFalse(model.activeAuthenticationPassed)
        }
    }

    func testRSACorrectDigestCannotExcuseWrongHeaderOrTrailer() throws {
        let key = try ReaderProtocolFixture.rsaKey()
        defer { EVP_PKEY_free(key) }
        let model = try ReaderProtocolFixture.rsaModel(key)
        let records = [
            ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128, header: 0x4A),
            ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128, trailer: [0x33]),
            ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128, trailer: [0x33, 0xCC]),
            ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128, trailer: [0xBC, 0xCC]),
            ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128, sha256: true, trailer: [0x34])
        ]
        for recovered in records {
            let signature = try ReaderProtocolFixture.rsaSignature(key: key, recovered: recovered)
            model.verifyActiveAuthentication(challenge: challenge, signature: signature)
            XCTAssertFalse(model.activeAuthenticationPassed)
        }
    }

    func testRSAErrorsShortRecoveryAndEmptyECDSAIntegersFailWithoutTrapping() throws {
        let key = try ReaderProtocolFixture.rsaKey(bits: 512)
        defer { EVP_PKEY_free(key) }
        XCTAssertThrowsError(try OpenSSLUtils.decryptRSASignature(signature: Data(repeating: 0xFF, count: 64), pubKey: key))
        let model = try ReaderProtocolFixture.rsaModel(key)
        let recovered: [UInt8] = [0x6A] + Array(repeating: 0, count: 61) + [0x35, 0xCC]
        model.verifyActiveAuthentication(challenge: challenge,
            signature: try ReaderProtocolFixture.rsaSignature(key: key, recovered: recovered))
        XCTAssertFalse(model.activeAuthenticationPassed)
        let ec = ReaderProtocolFixture.ecModel(key: P256.Signing.PrivateKey())
        let group = try XCTUnwrap(ec.getDataGroup(.DG15) as? DataGroup15)
        let publicKey = try XCTUnwrap(group.ecdsaPublicKey)
        XCTAssertFalse(OpenSSLUtils.verifySignature(data: challenge,
            signature: [0x30, 4, 2, 0, 2, 0], pubKey: publicKey, digestType: "ecdsa-sha256"))
    }

    func testRSARecoveryReleasesEveryBorrowedKeyReference() throws {
        let index = CRYPTO_get_ex_new_index(CRYPTO_EX_INDEX_RSA, 0, nil, nil, nil,
            { _, pointer, _, _, _, _ in pointer?.assumingMemoryBound(to: Int.self).pointee += 1 })
        XCTAssertGreaterThanOrEqual(index, 0)
        guard index >= 0 else { return }
        let released = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        released.initialize(to: 0)
        defer { released.deinitialize(count: 1); released.deallocate() }
        let key = try ReaderProtocolFixture.rsaKey()
        let rsa = try XCTUnwrap(EVP_PKEY_get0_RSA(key))
        XCTAssertEqual(RSA_set_ex_data(rsa, index, released), 1)
        let recovered = ReaderProtocolFixture.recoveredRSA(challenge: challenge, size: 128)
        let signature = try ReaderProtocolFixture.rsaSignature(key: key, recovered: recovered)
        for _ in 0..<3 {
            XCTAssertEqual(try OpenSSLUtils.decryptRSASignature(signature: Data(signature), pubKey: key), recovered)
        }
        EVP_PKEY_free(key)
        XCTAssertEqual(released.pointee, 1, "An extra retained RSA reference prevents its destructor")
    }
}
#endif
