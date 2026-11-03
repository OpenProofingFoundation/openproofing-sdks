#if os(iOS)
import CoreNFC
import Foundation
import XCTest
@testable import NFCPassportReader

final class PACETransportTests: XCTestCase {
    func testEveryAPDUStatusThroughProductionTransport() async throws {
        var status = 0
        let reader = TagReader { _ in (Data(), UInt8(status >> 8), UInt8(status & 255)) }
        let command = NFCISO7816APDU(instructionClass: 0, instructionCode: 0x84,
                                    p1Parameter: 0, p2Parameter: 0, data: Data(), expectedResponseLength: 8)
        for value in 0...65535 where value >> 8 != 0x61 {
            status = value
            do {
                _ = try await reader.send(cmd: command)
                XCTAssertEqual(value, 0x9000)
            } catch {
                XCTAssertNotEqual(value, 0x9000)
            }
        }
    }

    func testContinuationUsesGetResponseAndFinalStatus() async throws {
        var commands: [UInt8] = []
        let reader = TagReader { command in
            commands.append(command.instructionCode)
            return commands.count == 1 ? (Data([1]), 0x61, 2) : (Data([2, 3]), 0x90, 0)
        }
        let result = try await reader.getChallenge()
        XCTAssertEqual(result.data, [1, 2, 3])
        XCTAssertEqual(commands, [0x84, 0xC0])
    }

    func testCardAccessAbsenceRetainsExactStageAndStatus() async throws {
        var calls = 0
        var stages: [String] = []
        let reader = TagReader { _ in
            calls += 1
            return calls == 1 ? (Data(), 0x90, 0) : (Data(), 0x6A, 0x82)
        }
        do {
            _ = try await reader.readCardAccess { stages.append($0) }
            XCTFail("Missing CardAccess accepted")
        } catch NFCPassportReaderError.ResponseError(_, let sw1, let sw2) {
            XCTAssertEqual(sw1, 0x6A); XCTAssertEqual(sw2, 0x82)
        }
        XCTAssertEqual(stages, ["masterFile", "cardAccess"])
    }

    func testMasterFileFailureIsNotCardAccessAbsence() async throws {
        var stages: [String] = []
        let reader = TagReader { _ in (Data(), 0x6A, 0x82) }
        do { _ = try await reader.readCardAccess { stages.append($0) }; XCTFail("Accepted") }
        catch { XCTAssertEqual(stages, ["masterFile"]) }
    }

    func testUnsupportedMappingRefusedBeforeSendingCommands() throws {
        let reader = TagReader { _ in XCTFail("Unsupported PACE sent an APDU"); return (Data(), 0x90, 0) }
        XCTAssertThrowsError(try PACEHandler(cardAccess: syntheticCardAccess(mapping: 4), tagReader: reader))
    }

    func testSupportedEntrySelectedAfterUnsupportedEntry() throws {
        let reader = TagReader { _ in (Data(), 0x90, 0) }
        let entries = syntheticPACEEntry(mapping: 4) + syntheticPACEEntry(mapping: 2)
        let handler = try PACEHandler(cardAccess: CardAccess([0x31, UInt8(entries.count)] + entries), tagReader: reader)
        XCTAssertEqual(try handler.paceInfo.getMappingType(), .GM)
    }

    func testMSERejectionIsReportedBeforeNonce() async throws {
        let reader = TagReader { _ in (Data(), 0x69, 0x82) }
        let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
        do { try await handler.doPACE(mrzKey: "synthetic"); XCTFail("Accepted") }
        catch NFCPassportReaderError.ResponseError(_, let sw1, let sw2) {
            XCTAssertEqual(sw1, 0x69); XCTAssertEqual(sw2, 0x82)
        }
        XCTAssertEqual(handler.stage, "mseSetAT")
        XCTAssertNil(reader.secureMessaging)
    }

    func testMalformedNonceFailsWithoutCrashing() async throws {
        var calls = 0
        let reader = TagReader { _ in
            calls += 1
            return calls == 1 ? (Data(), 0x90, 0) : (Data([0x7c, 0]), 0x90, 0)
        }
        let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
        do { try await handler.doPACE(mrzKey: "synthetic"); XCTFail("Accepted") } catch {}
        XCTAssertEqual(handler.stage, "nonce")
        XCTAssertNil(reader.secureMessaging)
    }
}

func syntheticPACEEntry(mapping: UInt8 = 2) -> [UInt8] {
    // PACE ECDH, AES-128, version 2, brainpoolP256r1 (parameter 13).
    [0x30, 0x12, 0x06, 0x0A, 0x04, 0, 0x7F, 0, 7, 2, 2, 4, mapping, 2, 2, 1, 2, 2, 1, 13]
}
func syntheticCardAccess(mapping: UInt8 = 2) throws -> CardAccess {
    let entry = syntheticPACEEntry(mapping: mapping)
    return try CardAccess([0x31, UInt8(entry.count)] + entry)
}

extension PACETransportTests {
    func testCompletePACEAndFailuresThroughRealCryptographicExchange() async throws {
        for mode in [SyntheticPACEPeer.Mode.valid, .wrongToken, .malformedToken, .malformedKey] {
            let peer = SyntheticPACEPeer(mode)
            let reader = TagReader(exchange: peer.exchange)
            let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
            do {
                try await handler.doPACE(mrzKey: "synthetic")
                XCTAssertEqual(mode, .valid)
                XCTAssertEqual(handler.stage, "secureMessaging")
                XCTAssertNotNil(reader.secureMessaging)
                XCTAssertEqual(peer.step, 4)
            } catch {
                XCTAssertNotEqual(mode, .valid, "Synthetic PACE success failed: \(error)")
                XCTAssertNil(reader.secureMessaging)
                XCTAssertEqual(handler.stage, mode == .malformedKey ? "keyExchange" : "tokenVerification")
                XCTAssertFalse(String(describing: error).contains("expectedPICCToken"))
            }
        }
    }
}

#endif
