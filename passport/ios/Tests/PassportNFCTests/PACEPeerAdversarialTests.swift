#if os(iOS)
import CoreNFC
import Foundation
import OpenSSL
import XCTest
@testable import NFCPassportReader

/// Mutate otherwise valid peer responses; rejection must happen before the next protocol step.
/// The peer is only a transport fixture, not an independent cryptographic conformance oracle.
final class PACEPeerAdversarialTests: XCTestCase {
    func testTokenRejectsDuplicateAndTrailingFields() async throws {
        for corruption in 0..<4 {
            let peer = SyntheticPACEPeer(.valid)
            let reader = TagReader { command in
                let result = try await peer.exchange(command)
                guard peer.step == 4, command.instructionCode == 0x86 else { return result }
                let token = wrapDO(b: 0x86, arr: peer.chipToken)
                switch corruption {
                case 0: return (Data(wrapDO(b: 0x7C, arr: token + token)), 0x90, 0)
                case 1: return (Data(wrapDO(b: 0x7C, arr: token + [0x87, 0x00])), 0x90, 0)
                case 2: return (Data(wrapDO(b: 0x7C, arr: token + [0xFF])), 0x90, 0)
                default: return (Data(wrapDO(b: 0x7C, arr: token) + [0x7C, 0x00]), 0x90, 0)
                }
            }
            let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
            do {
                try await handler.doPACE(mrzKey: "synthetic")
                XCTFail("Accepted token corruption \(corruption)")
            } catch {}
            XCTAssertEqual(handler.stage, "tokenVerification", "corruption \(corruption)")
            XCTAssertNil(reader.secureMessaging, "corruption \(corruption)")
        }
    }

    func testInvalidEphemeralPointsRejectedBeforeTokenExchange() async throws {
        let invalidPoints: [[UInt8]] = [
            [], [0x00], [0x04], [0x04] + Array(repeating: 0, count: 64),
        ]
        for (index, point) in invalidPoints.enumerated() {
            let peer = SyntheticPACEPeer(.valid)
            var sentToken = false
            let reader = TagReader { command in
                if command.instructionCode == 0x86, peer.step == 3 {
                    sentToken = true
                    throw NFCPassportReaderError.UnexpectedError
                }
                let result = try await peer.exchange(command)
                guard command.instructionCode == 0x86, peer.step == 3 else { return result }
                return (Data(wrapDO(b: 0x7C, arr: wrapDO(b: 0x84, arr: point))), 0x90, 0)
            }
            let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
            do {
                try await handler.doPACE(mrzKey: "synthetic")
                XCTFail("Accepted invalid point \(index)")
            } catch {}
            XCTAssertFalse(sentToken, "Invalid point \(index) reached token exchange")
            XCTAssertEqual(handler.stage, "keyExchange", "point \(index)")
            XCTAssertNil(reader.secureMessaging)
        }
    }

    func testInvalidMappingPointsRejectedBeforeEphemeralExchange() async throws {
        let invalidPoints: [[UInt8]] = [
            [], [0x00], [0x04], [0x04] + Array(repeating: 0, count: 64),
        ]
        for (index, point) in invalidPoints.enumerated() {
            let peer = SyntheticPACEPeer(.valid)
            var sentEphemeralKey = false
            let reader = TagReader { command in
                if command.instructionCode == 0x86, peer.step == 2 {
                    sentEphemeralKey = true
                    throw NFCPassportReaderError.UnexpectedError
                }
                let result = try await peer.exchange(command)
                guard command.instructionCode == 0x86, peer.step == 2 else { return result }
                return (Data(wrapDO(b: 0x7C, arr: wrapDO(b: 0x82, arr: point))), 0x90, 0)
            }
            let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
            do {
                try await handler.doPACE(mrzKey: "synthetic")
                XCTFail("Accepted invalid mapping point \(index)")
            } catch {}
            XCTAssertFalse(sentEphemeralKey, "Invalid mapping point \(index) reached ephemeral exchange")
            XCTAssertEqual(handler.stage, "mapping", "point \(index)")
            XCTAssertNil(reader.secureMessaging)
        }
    }

    func testEphemeralKeyReflectionRejectedBeforeTokenExchange() async throws {
        let peer = SyntheticPACEPeer(.valid)
        var sentToken = false
        let reader = TagReader { command in
            if command.instructionCode == 0x86, peer.step == 3 {
                sentToken = true
                throw NFCPassportReaderError.UnexpectedError
            }
            let result = try await peer.exchange(command)
            guard command.instructionCode == 0x86, peer.step == 3 else { return result }
            let inner = try unwrapDO(tag: 0x7C, wrappedData: Array(command.data ?? Data()))
            let terminalKey = try unwrapDO(tag: 0x83, wrappedData: inner)
            return (Data(wrapDO(b: 0x7C, arr: wrapDO(b: 0x84, arr: terminalKey))), 0x90, 0)
        }
        let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
        do {
            try await handler.doPACE(mrzKey: "synthetic")
            XCTFail("Accepted reflected terminal key")
        } catch {}
        XCTAssertFalse(sentToken)
        XCTAssertEqual(handler.stage, "keyExchange")
        XCTAssertNil(reader.secureMessaging)
    }

    func testAuthenticationPublicKeyEncodingHasIndependentExpectedBytes() throws {
        let pair = try PACEInfo(oid: "0.4.0.127.0.7.2.2.4.2.2", version: 2, parameterId: 13).createMappingKey()
        defer { EVP_PKEY_free(pair) }
        let publicBytes = try XCTUnwrap(OpenSSLUtils.getPublicKeyData(from: pair))
        XCTAssertEqual(publicBytes.count, 65)
        let reader = TagReader { _ in XCTFail("Encoding must not transmit"); return (Data(), 0x90, 0) }
        let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
        // Construct the fixed BER header independently of encodePublicKey, oidToBytes and wrapDO.
        let expected: [UInt8] = [0x7F, 0x49, 0x4F, 0x06, 0x0A,
            0x04, 0x00, 0x7F, 0x00, 0x07, 0x02, 0x02, 0x04, 0x02, 0x02,
            0x86, 0x41] + publicBytes
        XCTAssertEqual(try handler.encodePublicKey(oid: "0.4.0.127.0.7.2.2.4.2.2", key: pair), expected)
    }
}

#endif
