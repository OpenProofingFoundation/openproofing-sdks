import XCTest
import os

// NFCPassportReader is iOS-only; run through the passport iOS test harness.
#if canImport(NFCPassportReader)
  import NFCPassportReader

  /// Asserts that the first recorded outcome wins and the continuation is delivered exactly
  /// once, only after release. Later terminal contenders must not overwrite the winner.
  ///
  /// Runs where NFCPassportReader can be imported (the iOS simulator via the app scheme); on macOS
  /// `swift test` the whole file compiles to nothing.
  final class NFCReadSettlementTests: XCTestCase {
    private enum Boom: Error { case dropped }

    private func settled<T>(
      _ body: (NFCReadSettlement<T>) -> Void,
      onSettled: @escaping (NFCReadSettlement<T>.Settler, Bool) -> Void = { _, _ in }
    ) async throws -> T {
      let settlement = NFCReadSettlement<T>(onSettled: onSettled)
      return try await withCheckedThrowingContinuation { continuation in
        settlement.arm(continuation)
        body(settlement)
        settlement.release()
      }
    }

    func testSuccessRecordedFirstBeatsALaterInvalidation() async throws {
      var events: [(NFCReadSettlement<Int>.Settler, Bool)] = []
      let value = try await settled(
        { (settlement: NFCReadSettlement<Int>) in
          XCTAssertTrue(settlement.record(.success(42), by: .readTask))
          // The echo of our own invalidate, or a timeout landing in the same instant.
          XCTAssertFalse(settlement.record(.failure(Boom.dropped), by: .sessionInvalidation))
          XCTAssertEqual(settlement.winner, .readTask)
        }, onSettled: { events.append(($0, $1)) })
      XCTAssertEqual(value, 42)
      XCTAssertEqual(events.map(\.0), [.readTask, .sessionInvalidation])
      XCTAssertEqual(events.map(\.1), [true, false])
    }

    func testAGenuineFirstInvalidationDecidesTheRead() async {
      do {
        _ = try await settled({ (settlement: NFCReadSettlement<Int>) in
          XCTAssertTrue(settlement.record(.failure(Boom.dropped), by: .sessionInvalidation))
          XCTAssertFalse(settlement.record(.success(1), by: .readTask))
        })
        XCTFail("expected the invalidation to throw")
      } catch {
        XCTAssertTrue(error is Boom)
      }
    }

    func testReaderAbortThenEchoResumesOnce() async {
      do {
        _ = try await settled({ (settlement: NFCReadSettlement<Int>) in
          XCTAssertTrue(settlement.record(.failure(Boom.dropped), by: .readerAbort))
          XCTAssertFalse(settlement.record(.failure(Boom.dropped), by: .sessionInvalidation))
          XCTAssertTrue(settlement.isSettled)
        })
        XCTFail("expected the abort to throw")
      } catch {
        XCTAssertTrue(error is Boom)
      }
    }

    func testTaskCancellationThenInvalidationEchoResumesOnce() async {
      do {
        _ = try await settled({ (settlement: NFCReadSettlement<Int>) in
          XCTAssertTrue(
            settlement.record(.failure(CancellationError()), by: .taskCancellation))
          XCTAssertFalse(
            settlement.record(.failure(Boom.dropped), by: .sessionInvalidation))
          XCTAssertEqual(settlement.winner, .taskCancellation)
        })
        XCTFail("expected cancellation to throw")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
    }

    func testOutcomeBeforeArmIsRetainedUntilArmAndRelease() async throws {
      let settlement = NFCReadSettlement<Int>()
      XCTAssertTrue(settlement.record(.success(1), by: .readTask))
      XCTAssertFalse(settlement.release(), "release waits until the continuation is armed")
      let value = try await withCheckedThrowingContinuation { continuation in
        settlement.arm(continuation)
      }
      XCTAssertEqual(value, 1)
      XCTAssertTrue(settlement.isReleased)
    }

    func testReleaseIsTheBoundaryBeforeTheCallerResumes() async throws {
      var events: [String] = []
      let settlement = NFCReadSettlement<Int>()
      let value = try await withCheckedThrowingContinuation { continuation in
        settlement.arm(continuation)
        XCTAssertTrue(settlement.record(.success(7), by: .readTask))
        XCTAssertFalse(settlement.isReleased)
        events.append("session invalidated")
        XCTAssertTrue(settlement.release())
      }
      events.append("caller resumed")
      XCTAssertEqual(value, 7)
      XCTAssertEqual(events, ["session invalidated", "caller resumed"])
    }

    func testASecondReleaseDeliversNothing() async throws {
      let settlement = NFCReadSettlement<Int>()
      let value = try await withCheckedThrowingContinuation { continuation in
        settlement.arm(continuation)
        XCTAssertTrue(settlement.record(.success(3), by: .readTask))
        XCTAssertTrue(settlement.release(), "the matching invalidation delivers")
        XCTAssertFalse(settlement.release(), "a duplicate invalidation echo delivers nothing")
      }
      XCTAssertEqual(value, 3)
      XCTAssertTrue(settlement.isReleased)
    }

    func testARecordAfterReleaseIsALosingNoOp() async throws {
      let settlement = NFCReadSettlement<Int>()
      let value = try await withCheckedThrowingContinuation { continuation in
        settlement.arm(continuation)
        XCTAssertTrue(settlement.record(.success(9), by: .readTask))
        XCTAssertTrue(settlement.release())
        XCTAssertFalse(
          settlement.record(.failure(Boom.dropped), by: .sessionInvalidation),
          "nothing may re-decide a released read")
      }
      XCTAssertEqual(value, 9)
    }

    func testConcurrentSettlersResumeExactlyOnce() async {
      // 64 racers from both contexts; exactly one may win, and the continuation must resume
      // exactly once (a second resume traps — this test would crash, not fail). Either outcome
      // may win the race; only the count is asserted.
      let wins = OSAllocatedUnfairLock(initialState: 0)
      do {
        _ = try await settled({ (settlement: NFCReadSettlement<Int>) in
          DispatchQueue.concurrentPerform(iterations: 64) { index in
            let won =
              index.isMultiple(of: 2)
              ? settlement.record(.success(index), by: .readTask)
              : settlement.record(.failure(Boom.dropped), by: .sessionInvalidation)
            if won {
              wins.withLock { $0 += 1 }
            }
          }
        })
      } catch {
        XCTAssertTrue(error is Boom)
      }
      XCTAssertEqual(wins.withLock { $0 }, 1)
    }
  }
#endif
