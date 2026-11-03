#if os(iOS)
import Foundation
import XCTest
@testable import NFCPassportReader

/// Response authentication must use the computed MAC, never the received bytes as its oracle.
final class SecureMessagingAdversarialTests: XCTestCase {
    func testIndependentDESStatusAndEncryptedResponseVectorsAreAccepted() throws {
        // Independent Python cryptography 49.0.0 DES-EDE3 CBC/ECB assembly, SSC=1.
        // No production mac/encryption helper constructs these expected response bytes.
        let vectors = [
            ("990290008e08cb91b7b65520a3b0", [UInt8]()),
            ("8709010cece8ada72d6f08990290008e081be910291d17b60c", [0x61, 2, 0xAA, 0xBB])
        ]
        for (wire, expected) in vectors {
            let response = try desChannel().unprotect(rapdu: ResponseAPDU(data: hexRepToBin(wire), sw1: 0x90, sw2: 0))
            XCTAssertEqual(response.data, expected)
            XCTAssertEqual(response.sw1, 0x90)
            XCTAssertEqual(response.sw2, 0)
        }
    }

    func testForgedDESMACAndAuthenticatedInvalidPaddingAreRefused() {
        let valid = hexRepToBin("8709010cece8ada72d6f08990290008e081be910291d17b60c")
        for index in (valid.count - 8)..<valid.count {
            var forged = valid; forged[index] ^= 1
            XCTAssertThrowsError(try desChannel().unprotect(rapdu: ResponseAPDU(data: forged, sw1: 0x90, sw2: 0))) {
                guard case NFCPassportReaderError.InvalidResponseChecksum = $0 else { return XCTFail("Forged DES MAC escaped authentication") }
            }
        }
        let badPadding = hexRepToBin("87090108d7b4fb629d0885990290008e082f7b486c8060004d")
        XCTAssertThrowsError(try desChannel().unprotect(rapdu: ResponseAPDU(data: badPadding, sw1: 0x90, sw2: 0))) {
            guard case NFCPassportReaderError.D087Malformed = $0 else { return XCTFail("Authenticated invalid padding was not refused") }
        }
        for count in 0..<valid.count {
            XCTAssertThrowsError(try desChannel().unprotect(rapdu: ResponseAPDU(data: Array(valid.prefix(count)), sw1: 0x90, sw2: 0)))
        }
    }

    private func desChannel() -> SecureMessaging {
        let key = hexRepToBin("0123456789abcdeffedcba9876543210")
        return SecureMessaging(encryptionAlgorithm: .DES, ksenc: key + key.prefix(8), ksmac: key,
            ssc: Array(repeating: 0, count: 8))
    }
    private let key = Array(repeating: UInt8(0x42), count: 16)
    private let status: [UInt8] = [0x99, 0x02, 0x90, 0x00]

    private func channel() -> SecureMessaging {
        SecureMessaging(encryptionAlgorithm: .AES, ksenc: key, ksmac: key,
                        ssc: Array(repeating: 0, count: 8))
    }

    private func authenticatedStatus() -> [UInt8] {
        // First incoming response increments the initial SSC from zero to one.
        let counter = Array(repeating: UInt8(0), count: 15) + [1]
        let digest = mac(algoName: .AES, key: key, msg: pad(counter + status, blockSize: 16))
        return status + [0x8E, 0x08] + digest.prefix(8)
    }

    func testCorrectAESResponseMACIsAccepted() throws {
        let response = try channel().unprotect(
            rapdu: ResponseAPDU(data: authenticatedStatus(), sw1: 0x90, sw2: 0))
        XCTAssertEqual(response.data, [])
        XCTAssertEqual(response.sw1, 0x90)
        XCTAssertEqual(response.sw2, 0)
    }

    func testEveryForgedAESResponseMACByteIsRejected() {
        XCTAssertThrowsError(try channel().unprotect(
            rapdu: ResponseAPDU(data: status + [0x8E, 0x08] + Array(repeating: 0, count: 8),
                                sw1: 0x90, sw2: 0))) { error in
            guard case NFCPassportReaderError.InvalidResponseChecksum = error else {
                return XCTFail("Zero response MAC must fail authentication")
            }
        }
        for position in 6..<14 {
            var forged = authenticatedStatus()
            forged[position] ^= 1
            XCTAssertThrowsError(try channel().unprotect(
                rapdu: ResponseAPDU(data: forged, sw1: 0x90, sw2: 0))) { error in
                guard case NFCPassportReaderError.InvalidResponseChecksum = error else {
                    return XCTFail("Forged MAC must fail authentication")
                }
            }
        }
    }

    func testTruncatedAndMalformedSecureResponsesFailClosedWithoutTrapping() {
        let valid = authenticatedStatus()
        var malformed = (0..<valid.count).map { Array(valid.prefix($0)) }
        malformed += [
            [0x87], [0x87, 0x81], [0x87, 0x82], [0x87, 0x82, 0x00],
            [0x87, 0x82, 0xFF, 0xFF, 0x01], [0x87, 0x7F, 0x01],
            [0x87, 0x01, 0x00] + valid,
            [0x98, 0x02, 0x90, 0x00] + Array(valid.dropFirst(4)),
            [0x99, 0x03, 0x90, 0x00] + Array(valid.dropFirst(4)),
            status + [0x8E, 0x07] + Array(valid.suffix(7)),
            status + [0x8E, 0x09] + Array(valid.suffix(8)) + [0],
            valid + [0]
        ]
        for bytes in malformed {
            XCTAssertThrowsError(try channel().unprotect(
                rapdu: ResponseAPDU(data: bytes, sw1: 0x90, sw2: 0)),
                "Malformed protected response accepted: \(bytes.count) bytes")
        }
    }
}
#endif
