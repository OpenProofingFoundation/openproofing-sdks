#if os(iOS)
  import CoreNFC
  import NFCPassportReader
  import XCTest
  @testable import PassportSDK
  @testable import PassportNFC

  final class PassportChipReaderTests: XCTestCase {
    private struct Diagnostic: LocalizedError {
      var errorDescription: String? { "SECRET APDU CONTENT" }
    }

    func testCancellationRemainsCancellationAcrossVendorWrapping() {
      for error: Error in [
        CancellationError(), NFCPassportReaderError.UserCanceled,
        NFCPassportReaderError.Unknown(CancellationError()),
        NFCPassportReaderError.Unknown(NFCReaderError(.readerSessionInvalidationErrorUserCanceled)),
      ] {
        XCTAssertEqual(PassportReaderEvents.failure(error), .cancelled)
      }
    }

    func testInternalDiagnosticsCannotBecomePublicErrorMessages() throws {
      for error: Error in [
        Diagnostic(), NFCPassportReaderError.Unknown(Diagnostic()),
        NFCPassportReaderError.ResponseError("SECRET APDU CONTENT", 0x6a, 0x82),
      ] {
        let failure = PassportReaderEvents.failure(error)
        XCTAssertEqual(failure, .readFailed)
        XCTAssertFalse(
          String(data: try JSONEncoder().encode(failure), encoding: .utf8)!.contains("SECRET"))
      }
    }

    func testVendorCompletionMessageDoesNotClaimTransportHasClosed() {
      XCTAssertEqual(PassportReaderEvents.event(.successfulRead), .transportFinishing)
    }

    func testUnverifiedModelCannotProduceEvidence() {
      XCTAssertThrowsError(try PassportObservationMapper.observation(NFCPassportModel())) {
        XCTAssertEqual($0 as? PassportReadFailure, .dataIntegrityFailure)
      }
    }

    @MainActor
    func testCancelledCallNeverRequestsPresentation() async throws {
      let reader = PassportChipReader(trustAnchorsURL: URL(fileURLWithPath: "/unused.pem"))
      let key = try PassportAccessKey(
        documentNumber: "L898902C", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")
      let task = Task { @MainActor in
        while !Task.isCancelled { await Task.yield() }
        do {
          _ = try await reader.read(
            accessKey: key, challenge: nil,
            displayMessage: { _ in
              XCTFail("Cancelled work must never open CoreNFC")
              return ""
            })
          XCTFail("Expected cancellation")
        } catch {
          XCTAssertEqual(error as? PassportReadFailure, .cancelled)
        }
      }
      task.cancel()
      await task.value
    }
  }
#endif
