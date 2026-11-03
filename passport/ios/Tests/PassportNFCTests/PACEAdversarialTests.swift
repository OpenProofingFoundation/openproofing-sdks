#if os(iOS)
import CoreNFC
import Foundation
import XCTest
@testable import NFCPassportReader

/// Negative cases derived from the protocol boundaries, not from the happy-path peer.
final class PACEAdversarialTests: XCTestCase {
    func testCancellationMustNeverTriggerBACFallback() {
        XCTAssertTrue(PassportReader.shouldEscapeProtocolFallback(after: CancellationError()),
                      "Cancellation must end this attempt rather than start another protocol")
        XCTAssertTrue(PassportReader.shouldEscapeProtocolFallback(
            after: NFCPassportReaderError.Unknown(CancellationError())),
            "Wrapping cancellation must not change its control-flow meaning")
    }

    func testECDHRejectsFiniteFieldDomainEvenThoughItsIdentifierIsRecognized() throws {
        for domain: UInt8 in [0, 1, 2] {
            var entry = syntheticPACEEntry()
            entry[entry.count - 1] = domain
            let access = try CardAccess([0x31, UInt8(entry.count)] + entry)
            let reader = TagReader { _ in
                XCTFail("An impossible ECDH/domain combination must fail before APDUs")
                return (Data(), 0x90, 0)
            }
            XCTAssertThrowsError(try PACEHandler(cardAccess: access, tagReader: reader),
                                 "Finite-field domain \(domain) was accepted for ECDH")
        }
    }

    func testInvalidDomainDoesNotShadowLaterUsablePACEEntry() throws {
        var invalid = syntheticPACEEntry()
        invalid[invalid.count - 1] = 0
        let entries = invalid + syntheticPACEEntry()
        let access = try CardAccess([0x31, UInt8(entries.count)] + entries)
        let handler = try PACEHandler(cardAccess: access, tagReader: TagReader { _ in
            XCTFail("Selection alone must not send commands")
            return (Data(), 0x90, 0)
        })
        XCTAssertEqual(handler.paceInfo.getParameterId(), 13)
    }

    func testGetResponseZeroStatusLengthMeans256Bytes() async throws {
        var commands: [NFCISO7816APDU] = []
        let reader = TagReader { command in
            commands.append(command)
            return commands.count == 1 ? (Data(), 0x61, 0) : (Data(repeating: 7, count: 256), 0x90, 0)
        }
        let response = try await reader.getChallenge()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last?.instructionCode, 0xC0)
        XCTAssertEqual(commands.last?.expectedResponseLength, 256,
                       "SW 6100 requests 256 bytes; Le=0 omits the response-length field")
        XCTAssertEqual(response.data.count, 256)
    }

    func testFinalContinuationErrorCannotBeHiddenByInitialData() async throws {
        var count = 0
        let reader = TagReader { _ in
            count += 1
            return count == 1 ? (Data([0x7C, 0]), 0x61, 1) : (Data(), 0x69, 0x82)
        }
        do {
            _ = try await reader.getChallenge()
            XCTFail("Partial data must not turn a failed continuation into success")
        } catch NFCPassportReaderError.ResponseError(_, let sw1, let sw2) {
            XCTAssertEqual(sw1, 0x69)
            XCTAssertEqual(sw2, 0x82)
        }
        XCTAssertEqual(count, 2)
    }

    func testNonceMustBePositiveMultipleOfCipherBlockBeforeMappingStarts() async throws {
        // BSI TR-03110-3 v2.2 A.3.3: positive multiple of the cipher block size.
        for count in [0, 1, 15, 17, 31] {
            var mappingAttempted = false
            var calls = 0
            let reader = TagReader { command in
                calls += 1
                if command.instructionCode == 0x22 { return (Data(), 0x90, 0) }
                if calls == 2 {
                    return (Data(wrapDO(b: 0x7C, arr: wrapDO(b: 0x80,
                        arr: Array(repeating: UInt8(0), count: count)))), 0x90, 0)
                }
                mappingAttempted = true
                throw NFCPassportReaderError.UnexpectedError
            }
            let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
            do {
                try await handler.doPACE(mrzKey: "synthetic")
                XCTFail("Invalid nonce of \(count) bytes was accepted")
            } catch {}
            XCTAssertFalse(mappingAttempted, "Invalid \(count)-byte nonce reached mapping")
            XCTAssertEqual(handler.stage, "nonce", "Invalid nonce must be diagnosed at ingress")
            XCTAssertNil(reader.secureMessaging)
        }
    }

    func testMultipleNonceBlocksAreSupported() async throws {
        for count in [16, 32] {
            var mappingAttempted = false
            var calls = 0
            let reader = TagReader { command in
                calls += 1
                if command.instructionCode == 0x22 { return (Data(), 0x90, 0) }
                if calls == 2 {
                    return (Data(wrapDO(b: 0x7C, arr: wrapDO(b: 0x80,
                        arr: Array(repeating: UInt8(0), count: count)))), 0x90, 0)
                }
                mappingAttempted = true
                throw NFCPassportReaderError.UnexpectedError
            }
            let handler = try PACEHandler(cardAccess: syntheticCardAccess(), tagReader: reader)
            do {
                try await handler.doPACE(mrzKey: "synthetic")
                XCTFail("Peer deliberately refuses the mapping command")
            } catch {}
            XCTAssertTrue(mappingAttempted, "Valid \(count)-byte nonce was refused")
            XCTAssertEqual(handler.stage, "mapping")
            XCTAssertNil(reader.secureMessaging)
        }
    }

    func testCancellationDuringInitialResponseStopsFurtherAPDUs() async {
        // Cancel a child task rather than the XCTest task; no timing or racing sleeps.
        await Task {
            var calls = 0
            let reader = TagReader { _ in
                calls += 1
                if calls == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return (Data(), 0x61, 1)
                }
                return (Data([0]), 0x90, 0)
            }
            do {
                _ = try await reader.getChallenge()
                XCTFail("Cancelled exchange returned success")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(calls, 1, "Cancellation must prevent the next GET RESPONSE")
        }.value
    }

    func testNonProgressingContinuationsAreBounded() async {
        enum HarnessStop: Error { case safetyLimit }
        var calls = 0
        let reader = TagReader { _ in
            calls += 1
            // Safety stop makes the regression test finite even against a broken loop.
            if calls == 4096 { throw HarnessStop.safetyLimit }
            return (Data(), 0x61, 1)
        }
        do {
            _ = try await reader.getChallenge()
            XCTFail("A never-ending continuation cannot be a successful response")
        } catch {
            XCTAssertFalse(error is HarnessStop, "Reader relied on the harness to stop an unbounded loop")
        }
        XCTAssertLessThan(calls, 4096)
    }
}

#endif
