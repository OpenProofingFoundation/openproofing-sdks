#if os(iOS)
import CoreNFC
import Foundation
import XCTest
@testable import NFCPassportReader

final class BACAdversarialTests: XCTestCase {
    func testSessionKeysRequireInitializedKeyAndNonceState() {
        XCTAssertThrowsError(try BACHandler().sessionKeys(data: Array(repeating: 0, count: 40))) { error in
            guard case NFCPassportReaderError.InvalidResponseChecksum = error else {
                return XCTFail("Unexpected uninitialized BAC error")
            }
        }
    }

    func testMalformedChallengeNeverSendsMutualAuthentication() async throws {
        for length in [0, 1, 7, 9, 16] {
            var instructions: [UInt8] = []
            let reader = TagReader { command in
                instructions.append(command.instructionCode)
                return (Data(repeating: 0x12, count: length), 0x90, 0)
            }
            // A failed reauthentication must discard the previous channel too.
            reader.secureMessaging = SecureMessaging(
                ksenc: Array(repeating: 1, count: 16),
                ksmac: Array(repeating: 2, count: 16), ssc: Array(repeating: 0, count: 8))
            do {
                try await BACHandler(tagReader: reader).performBACAndGetSessionKeys(mrzKey: "synthetic")
                XCTFail("Malformed \(length)-byte challenge accepted")
            } catch NFCPassportReaderError.InvalidResponseChecksum {}
            XCTAssertEqual(instructions, [0x84])
            XCTAssertNil(reader.secureMessaging)
        }
    }

    func testValidMACDoesNotExcuseWrongTerminalNonce() async throws {
        let peer = BACResponseProbe(.wrongTerminalNonce)
        let reader = TagReader(exchange: peer.exchange)
        do {
            _ = try await syntheticPassportReader().establishAccessControl(tagReader: reader, mrzKey: "synthetic")
            XCTFail("Authenticated response for the wrong terminal nonce accepted")
        } catch NFCPassportReaderError.InvalidResponseChecksum {}
        XCTAssertTrue(peer.mutualAuthenticationReached)
        XCTAssertNil(reader.secureMessaging)
    }

    func testCancelledValidBACResponseDoesNotInstallSecureMessaging() async throws {
        await Task {
            let peer = BACResponseProbe(.cancelOnResponse)
            let reader = TagReader(exchange: peer.exchange)
            do {
                _ = try await syntheticPassportReader().establishAccessControl(tagReader: reader, mrzKey: "synthetic")
                XCTFail("Cancelled BAC completed")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertTrue(peer.mutualAuthenticationReached)
            XCTAssertNil(reader.secureMessaging)
        }.value
    }

    func testMasterFileFailureIsNotReportedAsAbsentCardAccess() async throws {
        let peer = BACResponseProbe(.valid)
        var first = true
        let reader = TagReader { command in
            if first {
                first = false
                return (Data(), 0x6A, 0x82)
            }
            return try await peer.exchange(command)
        }
        let passport = try await syntheticPassportReader().establishAccessControl(tagReader: reader, mrzKey: "synthetic")
        XCTAssertEqual(passport.BACStatus, .success)
        XCTAssertEqual(passport.paceFailureStage, "masterFile")
        XCTAssertEqual(passport.paceFailureCode, "cardResponse")
        XCTAssertEqual(passport.paceFailureStatusWord, 0x6A82)
    }
}

private final class BACResponseProbe {
    enum Mode { case valid, wrongTerminalNonce, cancelOnResponse }
    let mode: Mode
    let challenge = Array(repeating: UInt8(0x12), count: 8)
    var mutualAuthenticationReached = false
    init(_ mode: Mode) { self.mode = mode }

    func exchange(_ command: NFCISO7816APDU) async throws -> (Data, UInt8, UInt8) {
        switch command.instructionCode {
        case 0xA4:
            return command.data == Data([0x01, 0x1C]) ? (Data(), 0x6A, 0x82) : (Data(), 0x90, 0)
        case 0x84:
            return (Data(challenge), 0x90, 0)
        case 0x82:
            mutualAuthenticationReached = true
            let (enc, auth) = try BACHandler().deriveDocumentBasicAccessKeys(mrz: "synthetic")
            let commandBytes = try XCTUnwrap(command.data)
            XCTAssertEqual(commandBytes.count, 40)
            let plain = tripleDESDecrypt(key: enc, message: Array(commandBytes.prefix(32)),
                                         iv: Array(repeating: 0, count: 8))
            var terminalNonce = Array(plain.prefix(8))
            if mode == .wrongTerminalNonce { terminalNonce[0] ^= 1 }
            let response = challenge + terminalNonce + Array(repeating: UInt8(0x34), count: 16)
            let cipher = tripleDESEncrypt(key: enc, message: response, iv: Array(repeating: 0, count: 8))
            let authenticated = cipher + mac(algoName: .DES, key: auth, msg: pad(cipher, blockSize: 8))
            if mode == .cancelOnResponse { withUnsafeCurrentTask { $0?.cancel() } }
            return (Data(authenticated), 0x90, 0)
        default:
            XCTFail("Unexpected command")
            throw NFCPassportReaderError.UnexpectedError
        }
    }
}

#endif
