#if os(iOS)
import CoreNFC
import CryptoKit
import Foundation
import XCTest
@testable import NFCPassportReader

final class PassportTerminalAuthenticationTests: XCTestCase {
    func testProductionFinishingSequenceRunsAAThenRemoteCAWithNoFollowingCommand() async throws {
        let key = P256.Signing.PrivateKey()
        let model = ReaderProtocolFixture.ecModel(key: key)
        let group = try ReaderProtocolFixture.caGroup()
        model.addDataGroup(.DG14, dataGroup: group)
        let probe = ReaderCommandProbe()
        let challenge: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let reader = PassportReader(tagAttemptLifecycle: ReaderProtocolFixture.lifecycle(model: model),
            aaChallenge: challenge, chipAuthenticationTerminal: { _ in
                XCTAssertEqual(probe.instructions, [0x88], "The terminal must be requested only after AA")
                return .init(protocolOID: "0.4.0.127.0.7.2.2.3.2.2", keyID: nil,
                    terminalPublicKey: [4, 1], protectedCommand: [0x0C, 0xB0, 0, 0, 1])
            })
        let transport = TagReader { command in
            probe.append(command.instructionCode)
            if command.instructionCode == 0x88 { return (try key.signature(for: Data(challenge)).rawRepresentation, 0x90, 0) }
            if command.instructionCode == 0x86 { return (Data([0x7C, 0]), 0x90, 0) }
            return (Data(), 0x90, 0)
        }
        try await reader.finishAuthentication(tagReader: transport)
        XCTAssertTrue(model.activeAuthenticationPassed)
        XCTAssertEqual(probe.instructions, [0x88, 0x22, 0x86, 0xB0])
        XCTAssertEqual(model.chipAuthenticationTerminalResponse, [0x90, 0])
    }

    func testTerminalFailureCannotBecomeAnEmptyOrSuccessfulChipResponse() async throws {
        let group = try ReaderProtocolFixture.caGroup()
        let model = NFCPassportModel(); model.addDataGroup(.DG14, dataGroup: group)
        let reader = PassportReader(tagAttemptLifecycle: ReaderProtocolFixture.lifecycle(model: model),
            chipAuthenticationTerminal: { _ in throw CancellationError() })
        let transport = TagReader { _ in XCTFail("A failed terminal must send no command"); return (Data(), 0x90, 0) }
        do { try await reader.finishAuthentication(tagReader: transport); XCTFail("Terminal failure accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(model.chipAuthenticationTerminalResponse, [])
    }
    func testActualTerminalCAEncodesAESAndTDEAKeysAndRetainsExactRawResponseLast() async throws {
        for aes in [false, true] {
            for keyID: Int? in [nil, 0, 7] {
                let group = try ReaderProtocolFixture.caGroup()
                let groupBytes = group.data
                let model = NFCPassportModel(); model.addDataGroup(.DG14, dataGroup: group)
                let oid = "0.4.0.127.0.7.2.2.3.2." + (aes ? "2" : "1")
                let key: [UInt8] = [4] + Array(repeating: 0x21, count: aes ? 260 : 64)
                let protected: [UInt8] = [0x0C, 0xB0, 0, 0, 2, 0x8E, 0, 0]
                let reader = PassportReader(tagAttemptLifecycle: ReaderProtocolFixture.lifecycle(model: model),
                    chipAuthenticationTerminal: { actual in
                        XCTAssertEqual(actual, groupBytes)
                        return .init(protocolOID: oid, keyID: keyID, terminalPublicKey: key, protectedCommand: protected)
                    })
                var commands: [NFCISO7816APDU] = []
                let transport = TagReader { command in
                    commands.append(command)
                    return command.instructionClass == 0x0C ? (Data([0x87, 0x01, 0x23]), 0x90, 1)
                        : (aes && command.instructionCode == 0x86 ? Data([0x7C, 0]) : Data(), 0x90, 0)
                }
                try await reader.doTerminalChipAuthenticationIfNecessary(tagReader: transport)
                XCTAssertEqual(commands.last?.data, Data([0x8E, 0]))
                XCTAssertEqual(commands.last?.instructionClass, 0x0C)
                XCTAssertEqual(commands.last?.instructionCode, 0xB0)
                XCTAssertEqual(model.chipAuthenticationTerminalResponse, [0x87, 1, 0x23, 0x90, 1])
                XCTAssertEqual(model.chipAuthenticationStatus, .notDone, "Only the remote terminal can judge its own channel")
                if aes {
                    XCTAssertEqual(commands.map(\.instructionCode), [0x22, 0x86, 0x86, 0xB0])
                    let keyIDBytes: [UInt8] = keyID.map { $0 == 0 ? [] : [0x84, 1, UInt8($0)] } ?? []
                    XCTAssertEqual(commands[0].data, Data([0x80, 10, 4, 0, 0x7F, 0, 7, 2, 2, 3, 2, 2] + keyIDBytes))
                    XCTAssertEqual(commands[1].instructionClass, 0x10)
                    XCTAssertEqual(commands[2].instructionClass, 0)
                    let combined = try commands.dropFirst().dropLast().flatMap { command -> [UInt8] in
                        try unwrapDO(tag: 0x7C, wrappedData: Array(command.data ?? Data()))
                    }
                    XCTAssertEqual(try unwrapDO(tag: 0x80, wrappedData: combined), key)
                } else {
                    XCTAssertEqual(commands.map(\.instructionCode), [0x22, 0xB0])
                    let keyIDBytes: [UInt8] = keyID.map { [0x84, 1, UInt8($0)] } ?? []
                    XCTAssertEqual(commands[0].data, Data([0x91, 65] + key + keyIDBytes))
                }
            }
        }
    }

    func testProtectedAccessChannelAuthenticatesHandshakeBeforeUnmodifiedRawTerminalRelay() async throws {
        for vector in ReaderProtocolFixture.protectedTerminalVectors {
            try await exerciseProtectedTerminal(vector, forgedReply: nil)
        }
    }

    func testForgedProtectedHandshakeResponseStopsBeforeRawRelayAndRetainsAccessChannel() async throws {
        for vector in ReaderProtocolFixture.protectedTerminalVectors {
            for index in vector.replies.indices {
                try await exerciseProtectedTerminal(vector, forgedReply: index)
            }
        }
    }

    private func exerciseProtectedTerminal(_ vector: ReaderProtocolFixture.ProtectedTerminalVector,
                                          forgedReply: Int?) async throws {
        let model = NFCPassportModel()
        model.addDataGroup(.DG14, dataGroup: try ReaderProtocolFixture.caGroup())
        let oid = "0.4.0.127.0.7.2.2.3.2." + (vector.terminalAES ? "2" : "1")
        let key: [UInt8] = [4] + Array(repeating: 0x21, count: vector.terminalAES ? 260 : 64)
        let rawCommand: [UInt8] = [0x0C, 0xB0, 1, 2, 2, 0x8E, 0, 0]
        let reader = PassportReader(tagAttemptLifecycle: ReaderProtocolFixture.lifecycle(model: model),
            chipAuthenticationTerminal: { _ in
                .init(protocolOID: oid, keyID: 7, terminalPublicKey: key, protectedCommand: rawCommand)
            })
        let accessKey = vector.accessAES ? Array(repeating: UInt8(0x42), count: 16)
            : hexRepToBin("0123456789abcdeffedcba9876543210")
        let channel = SecureMessaging(encryptionAlgorithm: vector.accessAES ? .AES : .DES,
            ksenc: vector.accessAES ? accessKey : accessKey + accessKey.prefix(8),
            ksmac: accessKey, ssc: Array(repeating: 0, count: 8))
        let peer = ReaderAccessPeer()
        var step = 0
        let transport = TagReader { command in
            defer { step += 1 }
            if step < vector.replies.count {
                XCTAssertTrue(peer.transport?.secureMessaging === channel, "Access keys must remain until every handshake response is authenticated")
                XCTAssertEqual(command.instructionCode, step == 0 ? 0x22 : 0x86)
                XCTAssertEqual(command.instructionClass, vector.terminalAES && step == 1 ? 0x1C : 0x0C)
                let digest = SHA256.hash(data: command.data ?? Data()).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, vector.bodyDigests[step], "Protected command/MAC must match the independent peer")
                var response = hexRepToBin(vector.replies[step])
                if step == forgedReply { response[response.count - 1] ^= 1 }
                return (Data(response), 0x90, 0)
            }
            XCTAssertEqual(step, vector.replies.count, "Raw relay is the last command")
            XCTAssertNil(peer.transport?.secureMessaging)
            XCTAssertEqual(command.instructionClass, rawCommand[0])
            XCTAssertEqual(command.instructionCode, rawCommand[1])
            XCTAssertEqual(command.p1Parameter, rawCommand[2])
            XCTAssertEqual(command.p2Parameter, rawCommand[3])
            XCTAssertEqual(command.data, Data([0x8E, 0]))
            XCTAssertEqual(command.expectedResponseLength, NFCISO7816APDU(data: Data(rawCommand))?.expectedResponseLength)
            return (Data([0x87, 1, 0x23]), 0x90, 1)
        }
        peer.transport = transport
        transport.secureMessaging = channel
        if let forgedReply {
            do {
                try await reader.doTerminalChipAuthenticationIfNecessary(tagReader: transport)
                XCTFail("A forged access-channel response reached the terminal relay")
            } catch {
                guard case NFCPassportReaderError.InvalidResponseChecksum = error else {
                    return XCTFail("Forged handshake response escaped MAC verification")
                }
            }
            XCTAssertEqual(step, forgedReply + 1)
            XCTAssertTrue(transport.secureMessaging === channel)
            XCTAssertEqual(model.chipAuthenticationTerminalResponse, [])
        } else {
            try await reader.doTerminalChipAuthenticationIfNecessary(tagReader: transport)
            XCTAssertEqual(step, vector.replies.count + 1)
            XCTAssertNil(transport.secureMessaging)
            XCTAssertEqual(model.chipAuthenticationTerminalResponse, [0x87, 1, 0x23, 0x90, 1])
        }
        XCTAssertEqual(model.chipAuthenticationStatus, .notDone)
    }

    func testOwnedParentCancellationDuringTerminalAwaitPreventsEveryLaterAPDUAndDrains() async throws {
        let group = try ReaderProtocolFixture.caGroup()
        let entered = expectation(description: "terminal await")
        let gate = ReaderTerminalGate(entered: entered)
        let owner = PassportTagTaskOwner()
        let probe = ReaderCommandProbe()
        let parent = Task {
            let model = NFCPassportModel(); model.addDataGroup(.DG14, dataGroup: group)
            let reader = PassportReader(tagAttemptLifecycle: ReaderProtocolFixture.lifecycle(model: model),
                chipAuthenticationTerminal: { _ in
                    await gate.wait()
                    return .init(protocolOID: "0.4.0.127.0.7.2.2.3.2.2", keyID: nil,
                        terminalPublicKey: [4, 1], protectedCommand: [0, 0xB0, 0, 0, 1])
                })
            let transport = TagReader { command in
                probe.append(command.instructionCode)
                return (Data(), 0x90, 0)
            }
            await withTaskCancellationHandler {
                owner.start {
                    do { try await reader.doTerminalChipAuthenticationIfNecessary(tagReader: transport) }
                    catch { XCTAssertTrue(error is CancellationError) }
                }
                await owner.drain()
            } onCancel: { owner.cancel() }
            return model.chipAuthenticationTerminalResponse
        }
        await fulfillment(of: [entered], timeout: 2)
        parent.cancel()
        XCTAssertFalse(owner.start { XCTFail("Cancelled reader reopened a task") })
        gate.release()
        let response = await parent.value
        XCTAssertEqual(probe.instructions, [])
        XCTAssertEqual(response, [])
    }

    func testCancelledRawTerminalResponseCannotBecomeEvidence() async throws {
        await Task {
            let transport = TagReader { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (Data([1]), 0x90, 0)
            }
            do {
                let command = try XCTUnwrap(NFCISO7816APDU(data: Data([0, 0xB0, 0, 0, 1])))
                _ = try await transport.transmit(command)
                XCTFail("Cancelled raw response returned")
            } catch { XCTAssertTrue(error is CancellationError) }
        }.value
    }
}

private final class ReaderAccessPeer {
    weak var transport: TagReader?
}

private final class ReaderTerminalGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    let entered: XCTestExpectation
    init(entered: XCTestExpectation) { self.entered = entered }
    private func store(_ value: CheckedContinuation<Void, Never>) {
        lock.lock(); continuation = value; lock.unlock()
    }
    func wait() async {
        await withCheckedContinuation { store($0); entered.fulfill() }
    }
    func release() {
        lock.lock(); let value = continuation; continuation = nil; lock.unlock()
        value?.resume()
    }
}

private final class ReaderCommandProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt8] = []
    var instructions: [UInt8] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ value: UInt8) { lock.lock(); values.append(value); lock.unlock() }
}
#endif
