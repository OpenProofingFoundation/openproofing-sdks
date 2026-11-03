import Foundation
import XCTest
@testable import KenshikiOperationBinding

final class RevocationRecoveryAdversarialTests: XCTestCase {
    private enum Failure: Error { case offline, malformed }
    private actor Service {
        var prepared = 0, authorized = 0, executed = 0, recovered = 0
        var offline = false
        var recoveryOffline = false
        func failRecovery() { recoveryOffline = true }
        var holdAuthorization = false
        var held: CheckedContinuation<Void, Never>?
        var authorizationStarted: CheckedContinuation<Void, Never>?
        func waitUntilAuthorizationStarted() async {
            if authorized > 0 { return }
            await withCheckedContinuation { authorizationStarted = $0 }
        }
        func hold() { holdAuthorization = true }
        func release() { held?.resume(); held = nil }
        var recovery: RevocationRecoveryController.Recovery = .notAuthorized
        func configure(offline: Bool, recovery: RevocationRecoveryController.Recovery) {
            self.offline = offline; self.recovery = recovery
        }
        func prepare(_ record: JournalRecord) throws -> RevocationRecoveryController.Preparation {
            prepared += 1
            let intent = record.intent
            let operation = try SealedOperation(applicationID: "synthetic.app", installationID: "installation-1", audience: "pulse-api",
                operationKind: intent.kind, operationID: intent.id, targetID: intent.resourceID, generation: "key-generation",
                expectedRevision: 0, challengeID: "challenge", issuedAt: 1_792_267_200, expiresAt: 1_792_267_500,
                contentDigest: SealedOperation.sha256(intent.content), purpose: "installation_deletion", recipient: nil)
            return .init(operation: operation, bytes: Data("exact approved request".utf8))
        }
        func authorize() async throws -> Data {
            authorized += 1
            if holdAuthorization {
                await withCheckedContinuation {
                    held = $0
                    authorizationStarted?.resume(); authorizationStarted = nil
                }
            }
            if offline { throw Failure.offline }
            return Data("authorized".utf8)
        }
        func recover() throws -> RevocationRecoveryController.Recovery { recovered += 1; if recoveryOffline { throw Failure.offline }; return recovery }
        func execute() -> Data { executed += 1; return Data("cleanup pending".utf8) }
        func counts() -> [Int] { [prepared, authorized, executed, recovered] }
    }
    private func journal() throws -> (OperationJournal, JournalIntent) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let journal = try journalFixture(url: directory.appendingPathComponent("deletion.sqlite"), namespace: "deletion")
        let intent = try journal.declare(resourceID: "installation-1", kind: "installation_delete", content: Data("{}".utf8),
            revoking: true, recoveryData: Data("synthetic deletion-only capability".utf8))
        return (journal, intent)
    }
    private func ports(_ service: Service) -> RevocationRecoveryController.Ports {
        .init(prepare: { try await service.prepare($0) }, authorize: { _ in try await service.authorize() },
            recover: { _ in try await service.recover() }, execute: { _ in await service.execute() },
            validateAuthorization: { _, data in guard data == Data("authorized".utf8) else { throw Failure.malformed } },
            validateCompletion: { _, data in
                guard data == Data("cleanup pending".utf8) || data == Data("completed".utf8) else { throw Failure.malformed }
                return data == Data("completed".utf8)
            })
    }
    func testOfflineAuthorizationRetainsExactRequestAndCannotExecute() async throws {
        let (journal, intent) = try journal(), service = Service()
        await service.configure(offline: true, recovery: .notAuthorized)
        let controller = RevocationRecoveryController(journal: journal)
        do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail("must remain pending") } catch Failure.offline {}
        let record = try XCTUnwrap(journal.current(resourceID: intent.resourceID))
        XCTAssertEqual(record.prepared, Data("exact approved request".utf8))
        XCTAssertNotNil(record.recoveryData); XCTAssertNil(record.authorization); XCTAssertNil(record.result)
        do { _ = try await controller.executeAuthorized(intent, ports: ports(service)); XCTFail("cannot erase before authorization") }
        catch OperationJournalError.missingIntent {}
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 0, 0])
    }
    func testLostAuthorizationResponseRecoversWithoutPreparingOrAuthorizingAgain() async throws {
        let (journal, intent) = try journal(), service = Service()
        await service.configure(offline: true, recovery: .notAuthorized)
        do { _ = try await RevocationRecoveryController(journal: journal).authorize(intent, ports: ports(service)); XCTFail() }
        catch Failure.offline {}
        await service.configure(offline: false, recovery: .authorized(Data("authorized".utf8)))
        let reopened = try journalFixture(url: journal.url, namespace: "deletion")
        _ = try await RevocationRecoveryController(journal: reopened).authorize(intent, ports: ports(service))
        let counts = await service.counts(); XCTAssertEqual(counts, [1, 1, 0, 1])
        XCTAssertEqual(try reopened.current(resourceID: intent.resourceID)?.authorization, Data("authorized".utf8))
    }
    func testGenericAbsentRecoveryNeverRefreshesTheApprovedProof() async throws {
        let (journal, intent) = try journal(), service = Service()
        await service.configure(offline: true, recovery: .notAuthorized)
        let controller = RevocationRecoveryController(journal: journal)
        for _ in 0..<2 {
            do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail() }
            catch Failure.offline {}
        }
        let counts = await service.counts()
        XCTAssertEqual(counts, [1, 2, 0, 1])
        XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.prepared, Data("exact approved request".utf8))
    }

    func testAmbiguousRecoveryCannotTriggerFreshPreparationOrExecution() async throws {
        let (journal, intent) = try journal(), service = Service()
        await service.configure(offline: true, recovery: .notAuthorized)
        let controller = RevocationRecoveryController(journal: journal)
        do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail() } catch Failure.offline {}
        await service.failRecovery()
        do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail() } catch Failure.offline {}
        let counts = await service.counts()
        XCTAssertEqual(counts, [1, 1, 0, 1])
        XCTAssertNil(try journal.current(resourceID: intent.resourceID)?.authorization)
    }

    func testOnlyExpiredUncommittedDiagnosticAllowsCallerToSeekFreshAuthorization() async throws {
        let (journal, intent) = try journal(), service = Service()
        await service.configure(offline: true, recovery: .notAuthorized)
        let controller = RevocationRecoveryController(journal: journal)
        do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail() } catch Failure.offline {}
        let expiry = try XCTUnwrap(journal.current(resourceID: intent.resourceID)?.operation?.expiresAt)
        await service.configure(offline: false, recovery: .notAuthorizedExpired(serverTime: expiry - 1))
        do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail() }
        catch OperationJournalError.staleIntent {}
        await service.configure(offline: false, recovery: .notAuthorizedExpired(serverTime: expiry))
        do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail("Inclusive expiry is still executable") }
        catch OperationJournalError.staleIntent {}
        await service.configure(offline: false, recovery: .notAuthorizedExpired(serverTime: expiry + 1))
        do { _ = try await controller.authorize(intent, ports: ports(service)); XCTFail() }
        catch RevocationRecoveryError.authorizationExpiredUncommitted(let serverTime) { XCTAssertEqual(serverTime, expiry + 1) }
        let counts = await service.counts()
        XCTAssertEqual(counts, [1, 1, 0, 3])
        XCTAssertEqual(try journal.current(resourceID: intent.resourceID)?.intent, intent)
        XCTAssertNil(try journal.current(resourceID: intent.resourceID)?.authorization)
    }

    func testLateAuthorizationCannotRestoreErasedRecoveryState() async throws {
        let (journal, intent) = try journal(), service = Service()
        await service.hold()
        let controller = RevocationRecoveryController(journal: journal)
        let operationPorts = ports(service)
        let pending = Task { try await controller.authorize(intent, ports: operationPorts) }
        await service.waitUntilAuthorizationStarted()
        let counts = await service.counts()
        XCTAssertEqual(counts[1], 1)
        try journal.erase()
        await service.release()
        do { _ = try await pending.value; XCTFail("late authorization must not restore erased state") }
        catch OperationJournalError.staleIntent {}
        XCTAssertNil(try journal.current(resourceID: intent.resourceID))
    }

    func testExternalCleanupPendingCannotBecomeACompletedErase() async throws {
        let (journal, intent) = try journal(), service = Service(), controller = RevocationRecoveryController(journal: journal)
        _ = try await controller.authorize(intent, ports: ports(service))
        let first = try await controller.executeAuthorized(intent, ports: ports(service))
        guard case .authorized = first else { return XCTFail("external cleanup remains pending") }
        XCTAssertNil(try journal.current(resourceID: intent.resourceID)?.result)
        await service.configure(offline: false, recovery: .completed(Data("cleanup pending".utf8)))
        let second = try await controller.executeAuthorized(intent, ports: ports(service))
        guard case .authorized = second else { return XCTFail("pending readout must not complete") }
        XCTAssertNil(try journal.current(resourceID: intent.resourceID)?.result)
        await service.configure(offline: false, recovery: .completed(Data("completed".utf8)))
        let final = try await controller.executeAuthorized(intent, ports: ports(service))
        guard case .completed = final else { return XCTFail("authenticated completion should finish") }
        let counts = await service.counts(); XCTAssertEqual(counts[2], 2)
    }
}
