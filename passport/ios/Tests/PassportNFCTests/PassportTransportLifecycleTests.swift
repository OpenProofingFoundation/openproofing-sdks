import XCTest

// Runs where NFCPassportReader can be imported (the iOS simulator via the app scheme); on macOS
// `swift test` the whole file compiles to nothing — same rule as NFCReadSettlementTests.
#if canImport(NFCPassportReader) && canImport(CoreNFC)
  import CoreNFC

  @testable import PassportSDK
  @testable import PassportNFC
  @testable import NFCPassportReader

  /// Exercises the value-level decisions used by CoreNFC callbacks and tag tasks.
  /// These assertions cover settlement ownership and error classification, not physical NFC I/O.
  final class PassportTransportLifecycleTests: XCTestCase {
    private struct DiagnosticError: LocalizedError {
      var errorDescription: String? { "SECRET-DIAG-42 internal state dump" }
    }

    private enum TerminalError: Error { case failed }

    func testCoreNFCSheetMessagesAreShortSingleLineAndDiagnosticFree() {
      XCTAssertEqual(
        NFCViewDisplayMessage.authenticatingWithPassport(40).description,
        "Authenticating passport — 40%")
      XCTAssertEqual(
        NFCViewDisplayMessage.readingDataGroupProgress(.DG1, 60).description,
        "Reading DG1 — 60%")

      let messages = [
        NFCViewDisplayMessage.requestPresentPassport.description,
        NFCViewDisplayMessage.authenticatingWithPassport(100).description,
        NFCViewDisplayMessage.readingDataGroupProgress(.DG14, 100).description,
        NFCViewDisplayMessage.error(.TagNotValid).description,
        NFCViewDisplayMessage.error(.MoreThanOneTagFound).description,
        NFCViewDisplayMessage.error(.ConnectionError).description,
        NFCViewDisplayMessage.error(.InvalidMRZKey).description,
        NFCViewDisplayMessage.error(.ResponseError("SECRET-APDU", 0x6A, 0x82)).description,
        NFCViewDisplayMessage.error(.UnexpectedError).description,
        NFCViewDisplayMessage.activeAuthentication.description,
        NFCViewDisplayMessage.successfulRead.description,
      ]
      for message in messages {
        XCTAssertLessThanOrEqual(message.count, 60)
        XCTAssertFalse(message.contains("\n"))
        XCTAssertFalse(message.contains("SECRET-APDU"))
      }
    }

    // MARK: - Detected-tag attempt lifecycle

    func testTransientLossRestartsPollingWithoutSettlingTheRead() {
      var lifecycle = PassportTagAttemptLifecycle()
      let settlement = NFCReadSettlement<Int>()

      guard case .beginAttempt(let attempt) = lifecycle.handle(.tagDetected([]))
      else { return XCTFail("the first detected tag must start an attempt") }
      XCTAssertEqual(lifecycle.handle(.transientLoss(attempt)), .restartPolling)
      XCTAssertFalse(settlement.isSettled, "physical loss must not settle the read")
      XCTAssertFalse(lifecycle.isTerminal)
    }

    func testRepeatedTransientLossesRemainRecoverableWithinTheSession() {
      var lifecycle = PassportTagAttemptLifecycle()

      for expectedGeneration in 1...3 {
        guard case .beginAttempt(let attempt) = lifecycle.handle(.tagDetected([]))
        else { return XCTFail("attempt \(expectedGeneration) was not admitted") }
        XCTAssertEqual(attempt, expectedGeneration)
        XCTAssertEqual(lifecycle.handle(.transientLoss(attempt)), .restartPolling)
      }

      XCTAssertNil(lifecycle.activeAttempt)
      XCTAssertFalse(lifecycle.isTerminal)
    }

    func testEveryRedetectionGetsAFreshAttemptGeneration() {
      var lifecycle = PassportTagAttemptLifecycle()
      let requestedGroups: [DataGroupId] = [.DG1, .DG2]

      guard case .beginAttempt(let first) = lifecycle.handle(.tagDetected(requestedGroups)),
        let firstState = lifecycle.attemptState
      else { return XCTFail("first tag was not admitted") }
      firstState.currentlyReadingDataGroup = .DG2
      firstState.dataGroupsToRead.removeAll()
      XCTAssertEqual(lifecycle.handle(.transientLoss(first)), .restartPolling)
      XCTAssertNil(lifecycle.attemptState, "all reader-owned attempt references must drop")

      guard case .beginAttempt(let second) = lifecycle.handle(.tagDetected(requestedGroups)),
        let secondState = lifecycle.attemptState
      else { return XCTFail("replacement tag was not admitted") }

      XCTAssertNotEqual(first, second)
      XCTAssertFalse(firstState === secondState)
      XCTAssertFalse(firstState.passport === secondState.passport)
      XCTAssertNil(secondState.currentlyReadingDataGroup)
      XCTAssertEqual(secondState.dataGroupsToRead, requestedGroups)
      XCTAssertNil(secondState.bacHandler)
      XCTAssertNil(secondState.caHandler)
      XCTAssertEqual(lifecycle.activeAttempt, second)
      XCTAssertEqual(lifecycle.handle(.transientLoss(first)), .none)
      XCTAssertEqual(lifecycle.handle(.success(first)), .none)
      XCTAssertEqual(lifecycle.handle(.fatalFailure(first)), .none)
      XCTAssertEqual(lifecycle.activeAttempt, second)
    }

    func testCancellationAndInvalidationPreventRetry() {
      for terminalEvent in [
        PassportTagAttemptLifecycle.Event.cancellation,
        PassportTagAttemptLifecycle.Event.invalidation,
      ] {
        var lifecycle = PassportTagAttemptLifecycle()
        guard case .beginAttempt(let attempt) = lifecycle.handle(.tagDetected([]))
        else { return XCTFail("initial tag was not admitted") }

        XCTAssertEqual(lifecycle.handle(terminalEvent), .settleFailure)
        XCTAssertEqual(lifecycle.handle(.transientLoss(attempt)), .none)
        XCTAssertEqual(lifecycle.handle(.tagDetected([])), .none)
        XCTAssertTrue(lifecycle.isTerminal)
      }
    }

    func testSuccessAfterARecoveredLossSettlesExactlyOnce() {
      var lifecycle = PassportTagAttemptLifecycle()
      let settlement = NFCReadSettlement<Int>()

      guard case .beginAttempt(let first) = lifecycle.handle(.tagDetected([]))
      else { return XCTFail("first tag was not admitted") }
      XCTAssertEqual(lifecycle.handle(.transientLoss(first)), .restartPolling)
      guard case .beginAttempt(let second) = lifecycle.handle(.tagDetected([]))
      else { return XCTFail("replacement tag was not admitted") }

      XCTAssertEqual(lifecycle.handle(.success(second)), .settleSuccess)
      XCTAssertTrue(settlement.record(.success(42), by: .readTask))
      XCTAssertEqual(lifecycle.handle(.success(second)), .none)
      XCTAssertEqual(lifecycle.handle(.cancellation), .none)
      XCTAssertFalse(
        settlement.record(.failure(CancellationError()), by: .taskCancellation))
      XCTAssertEqual(settlement.winner, .readTask)
    }

    func testFatalFailureSettlesAndPermanentlyClosesTheAttemptLifecycle() {
      var lifecycle = PassportTagAttemptLifecycle()
      let settlement = NFCReadSettlement<Int>()

      guard case .beginAttempt(let attempt) = lifecycle.handle(.tagDetected([]))
      else { return XCTFail("initial tag was not admitted") }
      XCTAssertEqual(lifecycle.handle(.fatalFailure(attempt)), .settleFailure)
      XCTAssertTrue(settlement.record(.failure(TerminalError.failed), by: .readerAbort))
      XCTAssertEqual(lifecycle.handle(.tagDetected([])), .none)
      XCTAssertEqual(lifecycle.handle(.transientLoss(attempt)), .none)
      XCTAssertEqual(settlement.winner, .readerAbort)
    }

    // MARK: - Defect 1: cancellation mid-APDU must not become .unknown

    func testASessionEndingCodeMidExchangeLeavesTheDecisionToTheSessionCallback() {
      XCTAssertNil(
        PassportReader.readTaskAbortError(
          for: NFCReaderError(.readerTransceiveErrorSessionInvalidated)),
        "the in-flight APDU only knows the session ended; the callback knows why")
      XCTAssertNil(
        PassportReader.readTaskAbortError(
          for: NFCReaderError(.readerSessionInvalidationErrorUserCanceled)))
      XCTAssertNil(
        PassportReader.readTaskAbortError(
          for: NFCReaderError(.readerSessionInvalidationErrorSessionTimeout)))
    }

    func testPhysicalTransportFailuresRetainTypedConnectionErrorFallback() {
      let physicalTransportCodes: [NFCReaderError.Code] = [
        .readerTransceiveErrorTagConnectionLost,
        .readerTransceiveErrorRetryExceeded,
        .readerTransceiveErrorTagResponseError,
        .readerTransceiveErrorTagNotConnected,
      ]
      for code in physicalTransportCodes {
        guard
          case .ConnectionError? = PassportReader.readTaskAbortError(
            for: NFCReaderError(code))
        else { return XCTFail("CoreNFC code \(code.rawValue) must retain typed recovery") }
      }
    }

    func testPhysicalTargetLossRestartsPollingInsideTheLiveSession() {
      let physicalTransportCodes: [NFCReaderError.Code] = [
        .readerTransceiveErrorTagConnectionLost,
        .readerTransceiveErrorRetryExceeded,
        .readerTransceiveErrorTagResponseError,
        .readerTransceiveErrorTagNotConnected,
      ]
      for code in physicalTransportCodes {
        XCTAssertTrue(
          PassportReader.shouldRestartPolling(after: NFCReaderError(code)),
          "CoreNFC code \(code.rawValue) must restart polling")
      }
      XCTAssertTrue(
        PassportReader.shouldRestartPolling(
          after: NFCPassportReaderError.ConnectionError),
        "the reader's typed target-loss error must use the same bounded retry")
    }

    func testFatalReaderAndForeignErrorsDoNotRestartPolling() {
      XCTAssertFalse(
        PassportReader.shouldRestartPolling(
          after: NFCPassportReaderError.InvalidMRZKey))
      XCTAssertFalse(PassportReader.shouldRestartPolling(after: DiagnosticError()))
    }

    func testOnlyTransportAndSessionEndingErrorsEscapeProtocolFallback() {
      XCTAssertTrue(
        PassportReader.shouldEscapeProtocolFallback(
          after: NFCReaderError(.readerTransceiveErrorRetryExceeded)))
      XCTAssertTrue(
        PassportReader.shouldEscapeProtocolFallback(
          after: NFCReaderError(.readerTransceiveErrorSessionInvalidated)))
      XCTAssertTrue(
        PassportReader.shouldEscapeProtocolFallback(
          after: NFCPassportReaderError.Unknown(
            NFCReaderError(.readerTransceiveErrorTagNotConnected))))
      XCTAssertTrue(
        PassportReader.shouldEscapeProtocolFallback(
          after: NFCPassportReaderError.Unknown(
            NFCReaderError(.readerSessionInvalidationErrorSessionTimeout))))
      XCTAssertFalse(
        PassportReader.shouldEscapeProtocolFallback(
          after: NFCPassportReaderError.InvalidMRZKey))
      XCTAssertFalse(PassportReader.shouldEscapeProtocolFallback(after: DiagnosticError()))
    }

    func testSessionEndingErrorsRemainOwnedByTheInvalidationCallback() {
      let sessionEndingCodes: [NFCReaderError.Code] = [
        .readerTransceiveErrorSessionInvalidated,
        .readerSessionInvalidationErrorUserCanceled,
        .readerSessionInvalidationErrorSessionTimeout,
        .readerSessionInvalidationErrorSessionTerminatedUnexpectedly,
        .readerSessionInvalidationErrorSystemIsBusy,
      ]

      for code in sessionEndingCodes {
        let error = NFCReaderError(code)
        XCTAssertFalse(
          PassportReader.shouldRestartPolling(after: error),
          "a dead session cannot be restarted for CoreNFC code \(code.rawValue)")
        XCTAssertNil(
          PassportReader.readTaskAbortError(for: error),
          "the invalidation callback must settle CoreNFC code \(code.rawValue)")
      }
    }

    func testReaderAndForeignErrorsStillAbortTheSession() {
      guard
        case .InvalidMRZKey? = PassportReader.readTaskAbortError(
          for: NFCPassportReaderError.InvalidMRZKey)
      else { return XCTFail("the reader's own errors pass through unchanged") }
      guard case .Unknown? = PassportReader.readTaskAbortError(for: DiagnosticError())
      else { return XCTFail("a foreign error still aborts, wrapped") }
    }

  }
#endif
