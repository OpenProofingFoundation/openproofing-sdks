import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class JournaledOperationAdversarialTests: XCTestCase {
    func testConcurrentSameIntentUsesOneFrozenDispatch() async throws {
        let journal = try journalFixture(url: location(), namespace: "shares")
        let intent = try intent(journal)
        let controller = JournaledOperationController(journal: journal)
        let log = OperationCallLog(), gate = OperationReplyGate()
        let ports = ports(log: log, dispatch: { record in
            await log.add("dispatch", record.prepared)
            return await gate.wait()
        })
        let first = Task { try await controller.perform(intent, ports: ports) }
        try await entered(gate)
        let second = Task { try await controller.perform(intent, ports: ports) }
        await gate.release(Data("bound-result".utf8))
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [Data("bound-result".utf8), Data("bound-result".utf8)])
        let calls = await log.calls()
        XCTAssertEqual(calls.filter { $0.0 == "prepare" }.count, 1)
        XCTAssertEqual(calls.filter { $0.0 == "dispatch" }.map { $0.1 }, [Data("frozen-request".utf8)])
    }

    func testRestartRecoversUncertainResultWithoutNewPreparationOrDispatch() async throws {
        let url = try location(), old = try journalFixture(url: url, namespace: "photos")
        let approved = try intent(old)
        let operation = try Self.operation(approved)
        try old.savePrepared(approved, operation: operation, bytes: Data("exact-original-binary-request".utf8))
        try old.beginDispatch(approved)
        let reopened = try journalFixture(url: url, namespace: "photos")
        let controller = JournaledOperationController(journal: reopened), log = OperationCallLog()
        let expected = Data("original-committed-receipt".utf8)
        let ports = JournaledOperationController.Ports(
            prepare: { _ in await log.add("prepare"); throw ProbeError.unexpected },
            recover: { record in
                await log.add("recover", record.prepared)
                return .completed(expected)
            }, dispatch: { _ in await log.add("dispatch"); throw ProbeError.unexpected },
            validateRecord: { record in
                guard record.operation == operation, record.prepared == Data("exact-original-binary-request".utf8) else { throw ProbeError.unexpected }
            }, validateResult: { _, result, _ in guard result == expected else { throw ProbeError.unexpected } })
        let result = try await controller.perform(approved, ports: ports)
        XCTAssertEqual(result, expected)
        let calls = await log.calls()
        XCTAssertEqual(calls.map { $0.0 }, ["recover"])
        XCTAssertEqual(calls.first?.1, Data("exact-original-binary-request".utf8))
        XCTAssertEqual(try reopened.current(resourceID: approved.resourceID)?.result, expected)
    }

    func testSupersedingIntentWhileTransportIsHeldRejectsLateSuccessProjection() async throws {
        let journal = try journalFixture(url: location(), namespace: "push")
        let old = try intent(journal), controller = JournaledOperationController(journal: journal)
        let log = OperationCallLog(), gate = OperationReplyGate()
        let operationPorts = ports(log: log, dispatch: { _ in await gate.wait() })
        let pending = Task { try await controller.perform(old, ports: operationPorts) }
        try await entered(gate)
        let newer = try journal.declare(resourceID: old.resourceID, kind: "protective_delete", content: Data("{\"deleted\":true}".utf8), revoking: true)
        await gate.release(Data("late-success".utf8))
        do { _ = try await pending.value; XCTFail("Superseded work projected a current success") }
        catch { XCTAssertEqual(error as? OperationJournalError, .staleIntent) }
        XCTAssertEqual(try journal.current(resourceID: old.resourceID)?.intent, newer)
        XCTAssertNil(try journal.current(resourceID: old.resourceID)?.result)
    }

    func testErasureDrainsHeldDispatchAndLateReplyCannotRestoreAcceptedData() async throws {
        let url = try location(), journal = try journalFixture(url: url, namespace: "photos")
        let approved = try intent(journal), controller = JournaledOperationController(journal: journal)
        let log = OperationCallLog(), gate = OperationReplyGate()
        let operationPorts = ports(log: log, dispatch: { _ in await gate.wait() })
        let pending = Task { try await controller.perform(approved, ports: operationPorts) }
        try await entered(gate)
        try journal.closeAllNamespaces()
        let draining = Task { await controller.closeAndDrain() }
        // Erasure removes every namespace payload even if an external provider ignores cancellation.
        try journal.eraseAllNamespaces()
        await gate.release(Data("late-private-result".utf8))
        await draining.value
        do { _ = try await pending.value; XCTFail("An erased flight returned a successful result") }
        catch { XCTAssertTrue(error is CancellationError || error as? OperationJournalError == .staleIntent) }
        let reopened = try journalFixture(url: url, namespace: "photos")
        XCTAssertNil(try reopened.current(resourceID: approved.resourceID))
        XCTAssertThrowsError(try intent(reopened))
        try reopened.resumeAllNamespacesAfterExplicitAdmission()
        await controller.resume()
        XCTAssertThrowsError(try reopened.validateAdmitted(approved))
    }

    func testHeldPreparationCannotSaveAfterCloseAndReopenWithoutPhysicalErasure() async throws {
        let journal = try journalFixture(url: location(), namespace: "shares")
        let approved = try intent(journal), controller = JournaledOperationController(journal: journal)
        let gate = OperationReplyGate(), closed = OperationCloseSignal()
        let ports = JournaledOperationController.Ports(prepare: { record in
            try await withTaskCancellationHandler(operation: {
                _ = await gate.wait()
                return .init(operation: try Self.operation(record.intent), bytes: Data("late-prepared-proof".utf8))
            }, onCancel: { Task { await closed.send() } })
        }, recover: { _ in throw ProbeError.unexpected }, dispatch: { _ in throw ProbeError.unexpected },
        validateRecord: { _ in }, validateResult: { _, _, _ in })
        let pending = Task { try await controller.prepare(approved, ports: ports) }
        try await entered(gate)
        try journal.closeAllNamespaces()
        let drain = Task { await controller.closeAndDrain(); await closed.send() }
        // Supports both an immediate durable closure and a controller that awaits canceled ports.
        await closed.wait()
        try journal.resumeAllNamespacesAfterExplicitAdmission()
        await gate.release(Data())
        await drain.value
        do { _ = try await pending.value; XCTFail("Old preparation returned across custody closure") }
        catch { XCTAssertTrue(error is CancellationError || error as? OperationJournalError == .staleIntent) }
        let record = try XCTUnwrap(journal.current(resourceID: approved.resourceID))
        XCTAssertNil(record.prepared, "Throwing after persisting a late proof is not a custody fence")
        XCTAssertNil(record.operation)
        XCTAssertEqual(record.state, "intent")
    }

    func testReadOnlyUnknownRecoveryDoesNotPrepareOrDispatchTheOriginalWrite() async throws {
        let journal = try journalFixture(url: location(), namespace: "shares")
        let approved = try intent(journal), operation = try Self.operation(approved)
        try journal.savePrepared(approved, operation: operation, bytes: Data("uncertain-original".utf8))
        try journal.beginDispatch(approved)
        let log = OperationCallLog(), controller = JournaledOperationController(journal: journal)
        let ports = JournaledOperationController.Ports(
            prepare: { _ in await log.add("prepare"); throw ProbeError.unexpected },
            recover: { record in await log.add("recover", record.prepared); return .notCompleted },
            dispatch: { _ in await log.add("dispatch"); throw ProbeError.unexpected },
            validateRecord: { _ in }, validateResult: { _, _, _ in throw ProbeError.unexpected })
        let result = try await controller.recover(approved, ports: ports)
        XCTAssertNil(result)
        let calls = await log.calls()
        XCTAssertEqual(calls.map { $0.0 }, ["recover"])
        XCTAssertEqual(calls.first?.1, Data("uncertain-original".utf8))
        let retained = try XCTUnwrap(journal.current(resourceID: approved.resourceID))
        XCTAssertNil(retained.result)
        XCTAssertEqual(retained.prepared, Data("uncertain-original".utf8))
        XCTAssertEqual(retained.state, "dispatching")
    }

    func testCachedAcceptedResultStillRequiresCurrentIdentityValidation() async throws {
        let journal = try journalFixture(url: location(), namespace: "shares")
        let approved = try intent(journal), operation = try Self.operation(approved)
        try journal.savePrepared(approved, operation: operation, bytes: Data("frozen-request".utf8))
        try journal.beginDispatch(approved)
        try journal.accepted(approved, result: Data("old-owner-result".utf8))
        let controller = JournaledOperationController(journal: journal), log = OperationCallLog()
        let ports = JournaledOperationController.Ports(
            prepare: { _ in await log.add("prepare"); throw ProbeError.unexpected },
            recover: { _ in await log.add("recover"); throw ProbeError.unexpected },
            dispatch: { _ in await log.add("dispatch"); throw ProbeError.unexpected },
            validateRecord: { record in
                guard record.operation?.installationID == "new-owner" else { throw ProbeError.identityMismatch }
            }, validateResult: { _, _, _ in throw ProbeError.unexpected })
        do { _ = try await controller.perform(approved, ports: ports); XCTFail("Cached success crossed owner identity") }
        catch { XCTAssertEqual(error as? ProbeError, .identityMismatch) }
        let calls = await log.calls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testWholeFileErasureFencesExistingAndLateOpenedNamespacesAcrossExplicitResume() throws {
        let url = try location()
        let shares = try journalFixture(url: url, namespace: "shares")
        let photos = try journalFixture(url: url, namespace: "photos")
        let oldShare = try intent(shares), oldPhoto = try intent(photos)
        let oldToken = try photos.generationToken()
        try shares.eraseAllNamespaces()
        let late = try journalFixture(url: url, namespace: "push")
        XCTAssertThrowsError(try intent(late))
        XCTAssertThrowsError(try shares.validateAdmitted(oldShare))
        XCTAssertThrowsError(try photos.validateAdmitted(oldPhoto))
        try shares.resumeAllNamespacesAfterExplicitAdmission()
        XCTAssertThrowsError(try photos.declare(resourceID: "resource", kind: "write", content: Data("{}".utf8), revoking: false, expectedGeneration: oldToken))
        XCTAssertThrowsError(try shares.validateAdmitted(oldShare))
        XCTAssertNil(try shares.current(resourceID: "resource"))
        XCTAssertNil(try photos.current(resourceID: "resource"))
        _ = try intent(late)
    }

    private func ports(log: OperationCallLog, dispatch: @escaping @Sendable (JournalRecord) async throws -> Data) -> JournaledOperationController.Ports {
        .init(prepare: { record in
            await log.add("prepare")
            return .init(operation: try Self.operation(record.intent), bytes: Data("frozen-request".utf8))
        }, recover: { _ in await log.add("recover"); throw ProbeError.unexpected }, dispatch: dispatch,
        validateRecord: { record in guard record.prepared != nil else { throw ProbeError.unexpected } },
        validateResult: { _, _, _ in })
    }
    private func intent(_ journal: OperationJournal) throws -> JournalIntent {
        try journal.declare(resourceID: "resource", kind: "write", content: Data("{}".utf8), revoking: false)
    }
    private static func operation(_ intent: JournalIntent) throws -> SealedOperation {
        try SealedOperation(applicationID: "app", installationID: "old-owner", audience: "service",
            operationKind: intent.kind, operationID: intent.id, targetID: intent.resourceID, generation: "key",
            expectedRevision: 0, challengeID: "challenge", issuedAt: 1000, expiresAt: 1300,
            contentDigest: SealedOperation.sha256(intent.content), purpose: "approved", recipient: nil)
    }
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile && !FileManager.default.fileExists(atPath: directory.path) {
                // A prior successful erasure may already have removed this test directory.
            }
        }
        return directory.appendingPathComponent("journal.sqlite")
    }
    private func entered(_ gate: OperationReplyGate) async throws {
        for _ in 0..<2000 {
            if await gate.entered { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw ProbeError.unexpected
    }
}

private enum ProbeError: Error, Equatable { case unexpected, identityMismatch }
private actor OperationCallLog {
    private var values: [(String, Data?)] = []
    func add(_ name: String, _ bytes: Data? = nil) { values.append((name, bytes)) }
    func calls() -> [(String, Data?)] { values }
}
private actor OperationReplyGate {
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var entered = false
    func wait() async -> Data { await withCheckedContinuation { continuation = $0; entered = true } }
    func release(_ value: Data) { continuation?.resume(returning: value); continuation = nil }
}

private actor OperationCloseSignal {
    private var sent = false
    private var waiter: CheckedContinuation<Void, Never>?
    func send() { sent = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if sent { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
