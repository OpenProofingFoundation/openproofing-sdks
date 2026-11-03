import Foundation
import XCTest

@testable import KenshikiOperationBinding

final class RegisteredKeyAttestationRetryTests: XCTestCase {
  func testKnownTransientReopensExactInputWithoutAnotherKeyOrChallenge() async throws {
    let fixture = RetryFixture()
    await expectTransient(fixture)
    let first = try await fixture.key()
    XCTAssertEqual(first.version, 2)
    XCTAssertEqual(first.phase, .retryableAttestation)
    fixture.clock.advance(2)
    _ = try await fixture.execute()
    let calls = await fixture.ports.snapshot()
    XCTAssertEqual(calls.generated, 1)
    XCTAssertEqual(calls.challenges, 1)
    XCTAssertEqual(calls.hashes, [fixture.hash, fixture.hash])
    XCTAssertEqual(calls.replays, 1)
    let final = try await fixture.key()
    XCTAssertEqual(final.phase, .prepared)
    XCTAssertNil(final.attestationAttempt)
    XCTAssertEqual(final.packet, Data("original-packet".utf8))
  }

  func testCooldownIsPersistedWithoutAnAutomaticRetryOrJournalWrite() async throws {
    let fixture = RetryFixture()
    await expectTransient(fixture)
    let before = await fixture.ports.snapshot()
    do { _ = try await fixture.execute(); XCTFail("Explicit retry is too early") }
    catch RegisteredKeyEnrollmentError.attestationRetryDeferred(let until) {
      XCTAssertEqual(until, fixture.clock.read().addingTimeInterval(2))
    }
    let after = await fixture.ports.snapshot()
    XCTAssertEqual(after.bytes, before.bytes)
    XCTAssertEqual(after.hashes.count, 1)
    XCTAssertEqual(after.generated, 1)
  }

  func testExpiryAfterAKnownTransientAttestsTheSameKeyWithANewChallenge() async throws {
    let fixture = RetryFixture()
    await expectTransient(fixture)
    fixture.clock.advance(301)
    let refreshedAt = fixture.clock.read()
    _ = try await fixture.execute()
    let calls = await fixture.ports.snapshot()
    XCTAssertEqual(calls.generated, 1)
    XCTAssertEqual(calls.challenges, 2)
    XCTAssertEqual(calls.hashes.count, 2)
    XCTAssertEqual(calls.replays, 1)
    XCTAssertEqual(calls.hashes, [RetryFixture.hash(1), RetryFixture.hash(2)])
    let final = try await fixture.key()
    XCTAssertEqual(final.keyID, "synthetic-key")
    XCTAssertEqual(final.clientInstallationID, "synthetic-owner")
    XCTAssertEqual(final.phase, .prepared)
    XCTAssertNil(final.attestationAttempt)
    XCTAssertEqual(final.packet, Data("packet-for-".utf8) + RetryFixture.context(2))
    XCTAssertEqual(final.packetExpiresAt, refreshedAt.addingTimeInterval(300))
  }

  func testRefreshKeepsTheFailureCountSoBackoffKeepsGrowing() async throws {
    let fixture = RetryFixture(failures: 2)
    await expectTransient(fixture)
    fixture.clock.advance(301)
    await expectTransient(fixture)
    let retained = try await fixture.key()
    XCTAssertEqual(retained.phase, .retryableAttestation)
    XCTAssertEqual(retained.attestationAttempt?.failures, 2)
    XCTAssertEqual(retained.attestationAttempt?.challenge.hash, RetryFixture.hash(2))
    XCTAssertEqual(retained.attestationAttempt?.nextAllowedAt, fixture.clock.read().addingTimeInterval(4))
  }

  func testFailedChallengeRefreshKeepsTheJournalForTheNextAttempt() async throws {
    let fixture = RetryFixture(failChallengeCall: 2)
    await expectTransient(fixture)
    let before = await fixture.ports.snapshot()
    fixture.clock.advance(301)
    await expectFailure(.network) { try await fixture.execute() }
    let after = await fixture.ports.snapshot()
    XCTAssertEqual(after.bytes, before.bytes)
    XCTAssertEqual(after.hashes.count, 1)
    _ = try await fixture.execute()
    let calls = await fixture.ports.snapshot()
    XCTAssertEqual(calls.generated, 1)
    XCTAssertEqual(calls.challenges, 3)
    XCTAssertEqual(calls.replays, 1)
    XCTAssertEqual(calls.hashes, [RetryFixture.hash(1), RetryFixture.hash(3)])
    let final = try await fixture.key()
    XCTAssertEqual(final.packet, Data("packet-for-".utf8) + RetryFixture.context(3))
  }

  func testExpiryAfterAnUnknownOutcomeNeverRefreshesTheChallengeOrErasesTheOwnedKey() async throws {
    let fixture = RetryFixture(outcome: .cancel)
    let task = Task { try await fixture.execute() }
    await expectFailure(.cancelled) { try await task.value }
    let before = await fixture.ports.snapshot()
    fixture.clock.advance(301)
    for _ in 0..<2 {
      await expectFailure(.expired) { try await fixture.execute() }
    }
    let after = await fixture.ports.snapshot()
    XCTAssertEqual(after.bytes, before.bytes)
    XCTAssertEqual(after.hashes.count, 1)
    XCTAssertEqual(after.challenges, 1)
    XCTAssertEqual(after.replays, 0)
  }

  func testRepeatedTransientFailuresRemainRetryableWithinOriginalLifetime() async throws {
    let fixture = RetryFixture(failures: 8)
    for _ in 0..<8 { await expectTransient(fixture); fixture.clock.advance(30) }
    _ = try await fixture.execute()
    let calls = await fixture.ports.snapshot()
    XCTAssertEqual(calls.generated, 1)
    XCTAssertEqual(calls.challenges, 1)
    XCTAssertEqual(calls.hashes.count, 9)
    XCTAssertTrue(calls.hashes.allSatisfy { $0 == fixture.hash })
  }

  func testV1AmbiguousAttestationDoesNotGuessAChallenge() async throws {
    let fixture = RetryFixture()
    let old = fixture.record(version: 1, phase: .attesting)
    let bytes = try JSONEncoder().encode(old)
    await fixture.ports.seed(bytes)
    await expectFailure(.interrupted) { try await fixture.execute() }
    let calls = await fixture.ports.snapshot()
    XCTAssertEqual(calls.bytes, bytes)
    XCTAssertEqual(calls.hashes.count, 0)
    XCTAssertEqual(calls.challenges, 0)
  }

  func testNonTransientOutcomeStaysAmbiguousAndCannotBeRetried() async throws {
    let fixture = RetryFixture(outcome: .permanent)
    await expectFailure(.permanent) { try await fixture.execute() }
    let before = await fixture.ports.snapshot()
    fixture.clock.advance(3)
    await expectFailure(.interrupted) { try await fixture.execute() }
    let after = await fixture.ports.snapshot()
    XCTAssertEqual(after.bytes, before.bytes)
    XCTAssertEqual(after.hashes.count, 1)
    let retained = try await fixture.key()
    XCTAssertEqual(retained.phase, .attesting)
  }

  func testCancellationCannotTurnAnUnknownOutcomeIntoRetryAuthority() async throws {
    let fixture = RetryFixture(outcome: .cancel)
    let task = Task { try await fixture.execute() }
    await expectFailure(.cancelled) { try await task.value }
    let retained = try await fixture.key()
    XCTAssertEqual(retained.phase, .attesting)
    XCTAssertEqual(retained.attestationAttempt?.failures, 0)
    await expectFailure(.interrupted) { try await fixture.execute() }
  }

  func testLateAppleSuccessCannotSubmitAnExpiredOriginalChallenge() async throws {
    let fixture = RetryFixture(outcome: .late)
    for _ in 0..<2 {
      await expectFailure(.expired) { try await fixture.execute() }
    }
    let calls = await fixture.ports.snapshot()
    XCTAssertEqual(calls.generated, 1)
    XCTAssertEqual(calls.hashes.count, 1)
    XCTAssertEqual(calls.challenges, 1)
    XCTAssertEqual(calls.replays, 0)
    let retained = try await fixture.key()
    XCTAssertEqual(retained.phase, .attesting)
    XCTAssertNil(retained.packet)
  }

  func testFailedRetryJournalWriteCannotGrantAnotherPlatformAttempt() async throws {
    let fixture = RetryFixture(failRetrySave: true)
    await expectFailure(.storage) { try await fixture.execute() }
    let before = await fixture.ports.snapshot()
    fixture.clock.advance(3)
    await expectFailure(.interrupted) { try await fixture.execute() }
    let after = await fixture.ports.snapshot()
    XCTAssertEqual(after.bytes, before.bytes)
    XCTAssertEqual(after.hashes.count, 1)
    XCTAssertEqual(after.replays, 0)
  }

  func testMalformedRetainedInputRefusesBeforePlatformWork() async throws {
    for mutation in 0..<5 {
      let fixture = RetryFixture()
      var record = fixture.record(version: 2, phase: .retryableAttestation)
      record.attestationAttempt = .init(challenge: .init(
        hash: mutation == 0 ? Data() : fixture.hash,
        expiresAt: fixture.clock.read().addingTimeInterval(300),
        context: mutation == 1 ? Data(repeating: 1, count: 16_385) : Data("original-context".utf8)),
        failures: mutation == 4 ? 0 : 1, nextAllowedAt: mutation == 2 ? .distantFuture : fixture.clock.read())
      if mutation == 3 { record.packet = Data("unexpected-packet".utf8) }
      let bytes = try JSONEncoder().encode(record)
      await fixture.ports.seed(bytes)
      await expectFailure(.identityMismatch) { try await fixture.execute() }
      let calls = await fixture.ports.snapshot()
      XCTAssertEqual(calls.bytes, bytes)
      XCTAssertTrue(calls.hashes.isEmpty)
      XCTAssertEqual(calls.generated, 0)
    }
  }

  func testV2InitialStateWithoutRetryPolicyPreservesJournalBeforeAnyWork() async throws {
    for phase in [RegisteredKeyEnrollmentRecord.Phase.generated, .attesting, .retryableAttestation] {
      let fixture = RetryFixture()
      var record = fixture.record(version: 2, phase: phase)
      if phase != .generated {
        record.attestationAttempt = .init(challenge: .init(hash: fixture.hash,
          expiresAt: fixture.clock.read().addingTimeInterval(300), context: Data("original-context".utf8)),
          failures: phase == .retryableAttestation ? 1 : 0, nextAllowedAt: fixture.clock.read())
      }
      let bytes = try JSONEncoder().encode(record)
      await fixture.ports.seed(bytes)
      await expectFailure(.interrupted) { try await fixture.execute(withPolicy: false) }
      let calls = await fixture.ports.snapshot()
      XCTAssertEqual(calls.bytes, bytes)
      XCTAssertEqual(calls.challenges, 0)
      XCTAssertTrue(calls.hashes.isEmpty)
    }
  }

  private func expectTransient(_ fixture: RetryFixture) async {
    await expectFailure(.transient) { try await fixture.execute() }
  }

  private func expectFailure<Result>(
    _ expected: ExpectedFailure, file: StaticString = #filePath, line: UInt = #line,
    operation: () async throws -> Result
  ) async {
    do {
      _ = try await operation()
      XCTFail("Expected \(expected) failure", file: file, line: line)
    } catch {
      XCTAssertEqual(ExpectedFailure(error), expected, "Unexpected failure: \(error)", file: file, line: line)
    }
  }

  private enum ExpectedFailure: Equatable {
    case transient, permanent, storage, network, cancelled, expired, interrupted, identityMismatch

    init?(_ error: Error) {
      switch error {
      case RetryTestError.transient: self = .transient
      case RetryTestError.permanent: self = .permanent
      case RetryTestError.storage: self = .storage
      case RetryTestError.network: self = .network
      case is CancellationError: self = .cancelled
      case RegisteredKeyEnrollmentError.attestationChallengeExpired: self = .expired
      case RegisteredKeyEnrollmentError.interruptedAttestation: self = .interrupted
      case RegisteredKeyEnrollmentError.identityMismatch: self = .identityMismatch
      default: return nil
      }
    }
  }
}

private enum RetryTestError: Error { case transient, permanent, storage, network }
private enum RetryOutcome: Sendable { case transient, permanent, cancel, late }
private final class RetryClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value = Date(timeIntervalSince1970: 1_800_000_000)
  func read() -> Date { lock.withLock { value } }
  func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
private struct RetryFixture: Sendable {
  let ports: RetryPorts
  let clock: RetryClock
  let hash = Data(repeating: 7, count: 32)
  let origin: URL
  private static var syntheticOrigin: URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "registration.invalid"
    return components.url!
  }
  init(failures: Int = 1, outcome: RetryOutcome = .transient, failRetrySave: Bool = false,
    failChallengeCall: Int? = nil, origin: URL = RetryFixture.syntheticOrigin) {
    let clock = RetryClock()
    self.clock = clock
    self.origin = origin
    ports = RetryPorts(failures: failures, outcome: outcome, clock: clock, failRetrySave: failRetrySave,
      failChallengeCall: failChallengeCall)
  }
  func record(version: Int, phase: RegisteredKeyEnrollmentRecord.Phase) -> RegisteredKeyEnrollmentRecord {
    .init(version: version, keyID: "synthetic-key", backendBaseURL: origin, environment: "production",
      clientInstallationID: "synthetic-owner", phase: phase)
  }
  func key() async throws -> RegisteredKeyEnrollmentRecord {
    let snapshot = await ports.snapshot()
    return try JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self, from: XCTUnwrap(snapshot.bytes))
  }
  func execute(withPolicy: Bool = true) async throws -> (RegisteredKeyEnrollmentRecord, Data) {
    try await RegisteredKeyEnrollmentCustody(ports: ports.ports()).execute(service: origin,
      environment: "production", original: nil, makeClientID: { "synthetic-owner" }, profile: .init(
        challenge: { _ in
          let issued = try await ports.challenge()
          return .init(hash: Self.hash(issued), expiresAt: clock.read().addingTimeInterval(300),
            context: Self.context(issued))
        }, packet: { _, challenge, _ in
          // The packet names the context it was built from, so a test can see which challenge it used.
          challenge.context == Self.context(1) ? Data("original-packet".utf8)
            : Data("packet-for-".utf8) + challenge.context
        }, replay: { _, _ in await ports.replay(); return Data("synthetic-result".utf8) },
        recover: { _ in XCTFail("Initial attempt cannot recover registered authority"); return Data() },
        isUnknownKey: { _ in false }, attestationRetry: withPolicy ? .init(now: { clock.read() },
          isRetryable: { if case RetryTestError.transient = $0 { return true }; return false },
          validate: { _, challenge in
            guard (1...16).contains(where: { challenge.hash == Self.hash($0) && challenge.context == Self.context($0) })
            else { throw RegisteredKeyEnrollmentError.identityMismatch }
          }, delay: { failures in min(30, 2 * pow(2, Double(min(failures - 1, 4)))) }) : nil), now: clock.read())
  }
  /// The Nth challenge the synthetic service issues: the first is the original, later ones refreshed.
  static func hash(_ issued: Int) -> Data { Data(repeating: issued == 1 ? 7 : UInt8(100 + issued), count: 32) }
  static func context(_ issued: Int) -> Data {
    Data((issued == 1 ? "original-context" : "refreshed-context-\(issued)").utf8)
  }
}
private actor RetryPorts {
  struct Snapshot: Sendable {
    let bytes: Data?; let generated: Int; let hashes: [Data]; let challenges: Int; let replays: Int
  }
  private var bytes: Data?
  private var generated = 0
  private var challenges = 0
  private var replays = 0
  private var hashes: [Data] = []
  private let failures: Int
  private let outcome: RetryOutcome
  private let clock: RetryClock
  private let failRetrySave: Bool
  private let failChallengeCall: Int?
  init(failures: Int, outcome: RetryOutcome, clock: RetryClock, failRetrySave: Bool, failChallengeCall: Int?) {
    self.failures = failures; self.outcome = outcome; self.clock = clock; self.failRetrySave = failRetrySave
    self.failChallengeCall = failChallengeCall
  }
  func seed(_ data: Data) { bytes = data }
  func challenge() throws -> Int {
    challenges += 1
    if challenges == failChallengeCall { throw RetryTestError.network }
    return challenges
  }
  func replay() { replays += 1 }
  func snapshot() -> Snapshot { .init(bytes: bytes, generated: generated, hashes: hashes, challenges: challenges, replays: replays) }
  nonisolated func ports() -> RegisteredKeyEnrollmentPorts {
    .init(load: { await self.snapshot().bytes }, save: { try await self.save($0) },
      generate: { await self.generate() }, attest: { _, hash in try await self.attest(hash) },
      assert: { _, _ in XCTFail("No assertion belongs in an initial attempt"); return Data() })
  }
  private func generate() -> String { generated += 1; return "synthetic-key" }
  private func save(_ data: Data) throws {
    let key = try JSONDecoder().decode(RegisteredKeyEnrollmentRecord.self, from: data)
    if failRetrySave, key.phase == .retryableAttestation { throw RetryTestError.storage }
    bytes = data
  }
  private func attest(_ hash: Data) throws -> Data {
    hashes.append(hash)
    if hashes.count <= failures {
      switch outcome {
      case .transient: throw RetryTestError.transient
      case .permanent: throw RetryTestError.permanent
      case .cancel: throw CancellationError()
      case .late: clock.advance(301)
      }
    }
    return Data("synthetic-attestation".utf8)
  }
}
