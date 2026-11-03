#if os(iOS)
import CoreNFC
import Foundation
import XCTest
@testable import NFCPassportReader

final class PACEFallbackTests: XCTestCase {
    func testAbsentCardAccessFallsBackToAuthenticatedBACAndKeepsCause() async throws {
        let peer = SyntheticBACPeer()
        let reader = TagReader(exchange: peer.exchange)
        let passport = try await syntheticPassportReader().establishAccessControl(tagReader: reader, mrzKey: "synthetic")
        XCTAssertEqual(passport.PACEStatus, .failed)
        XCTAssertEqual(passport.BACStatus, .success)
        XCTAssertEqual(passport.paceFailureStage, "cardAccess")
        XCTAssertEqual(passport.paceFailureCode, "cardAccessAbsent")
        XCTAssertEqual(passport.paceFailureStatusWord, 0x6A82)
        XCTAssertNotNil(reader.secureMessaging)
        XCTAssertEqual(peer.instructions, [0xA4, 0xA4, 0xA4, 0x84, 0x82])
    }

    func testPACEFileReadFailureIsNotMisreportedAsAbsentFile() async throws {
        let peer = SyntheticBACPeer()
        let reader = TagReader { command in
            if command.instructionCode == 0xA4 && command.data == Data([0x01, 0x1C]) {
                return (Data(), 0x90, 0)
            }
            if command.instructionCode == 0xB0 { return (Data(), 0x6A, 0x82) }
            return try await peer.exchange(command)
        }
        let passport = try await syntheticPassportReader().establishAccessControl(tagReader: reader, mrzKey: "synthetic")
        XCTAssertEqual(passport.BACStatus, .success)
        XCTAssertEqual(passport.paceFailureStage, "cardAccessRead")
        XCTAssertEqual(passport.paceFailureCode, "cardResponse")
    }

    func testUnverifiedBACResponseCannotCompleteFallback() async throws {
        for mode in [SyntheticBACPeer.Mode.badMAC, .wrongNonce, .truncated] {
            let peer = SyntheticBACPeer(mode)
            let reader = TagReader(exchange: peer.exchange)
            do {
                _ = try await syntheticPassportReader().establishAccessControl(tagReader: reader, mrzKey: "synthetic")
                XCTFail("Unauthenticated BAC accepted")
            } catch NFCPassportReaderError.InvalidResponseChecksum {}
            XCTAssertNil(reader.secureMessaging)
        }
    }

    func testCancellationDoesNotSelectApplicationOrStartBAC() async throws {
        var count = 0
        let reader = TagReader { _ in count += 1; throw CancellationError() }
        do {
            _ = try await syntheticPassportReader().establishAccessControl(tagReader: reader, mrzKey: "synthetic")
            XCTFail("Cancellation swallowed")
        } catch is CancellationError {}
        XCTAssertEqual(count, 1)
    }
}

private final class SyntheticBACPeer {
    enum Mode { case valid, badMAC, wrongNonce, truncated }
    let mode: Mode
    var instructions: [UInt8] = []
    let challenge = [UInt8](repeating: 0x12, count: 8)
    init(_ mode: Mode = .valid) { self.mode = mode }
    func exchange(_ command: NFCISO7816APDU) async throws -> (Data, UInt8, UInt8) {
        instructions.append(command.instructionCode)
        switch command.instructionCode {
        case 0xA4:
            return command.data == Data([0x01, 0x1C]) ? (Data(), 0x6A, 0x82) : (Data(), 0x90, 0)
        case 0x84: return (Data(challenge), 0x90, 0)
        case 0x82:
            let (enc, auth) = try BACHandler().deriveDocumentBasicAccessKeys(mrz: "synthetic")
            let bytes = Array(command.data ?? Data())
            XCTAssertEqual(bytes.count, 40)
            let request = tripleDESDecrypt(key: enc, message: Array(bytes.prefix(32)), iv: Array(repeating: 0, count: 8))
            XCTAssertEqual(Array(request[8..<16]), challenge)
            var clear = challenge + Array(request.prefix(8)) + Array(repeating: UInt8(0x34), count: 16)
            if mode == .wrongNonce { clear[0] ^= 1 }
            let encrypted = tripleDESEncrypt(key: enc, message: clear, iv: Array(repeating: 0, count: 8))
            var response = encrypted + mac(algoName: .DES, key: auth, msg: pad(encrypted, blockSize: 8))
            if mode == .badMAC { response[39] ^= 1 }
            if mode == .truncated { response = Array(response.prefix(3)) }
            return (Data(response), 0x90, 0)
        default: XCTFail("Unexpected BAC APDU"); throw NFCPassportReaderError.UnexpectedError
        }
    }
}

func syntheticPassportReader() -> PassportReader {
    var lifecycle = PassportTagAttemptLifecycle()
    guard case .beginAttempt = lifecycle.handle(.tagDetected([])) else {
        preconditionFailure("Synthetic tag attempt did not start")
    }
    return PassportReader(tagAttemptLifecycle: lifecycle)
}

#endif
