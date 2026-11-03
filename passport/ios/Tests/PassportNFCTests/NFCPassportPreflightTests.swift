import XCTest

#if canImport(NFCPassportReader) && canImport(CoreNFC)
    import CoreNFC
    @testable import NFCPassportReader

    final class NFCPassportPreflightTests: XCTestCase {
        // MARK: - Defect 4: Swift task cancellation propagates, and preflight failures release

        func testAnAlreadyCancelledTaskIsCancellationNotAReadAttempt() async {
            let reader = PassportReader()
            let task = Task { () -> Error? in
                // Deterministically enter the read only after cancellation has landed.
                while !Task.isCancelled { await Task.yield() }
                do {
                    _ = try await reader.readPassportUnverified(mrzKey: "0000000000")
                    return nil
                } catch {
                    return error
                }
            }
            task.cancel()
            let thrown = await task.value
            XCTAssertTrue(
                thrown is CancellationError,
                "expected CancellationError, got \(String(describing: thrown))")
        }

        func testUnavailableHardwareThrowsNotSupportedAndReleasesTheSingleUseLease() async throws {
            try XCTSkipIf(
                NFCTagReaderSession.readingAvailable,
                "this pin needs hardware without NFC reading (the simulator)")
            let reader = PassportReader()
            for attempt in 1...2 {
                do {
                    _ = try await reader.readPassportUnverified(mrzKey: "0000000000")
                    XCTFail("attempt \(attempt): the simulator cannot read tags")
                } catch NFCPassportReaderError.NFCNotSupported {
                    // The lease released: attempt 2 must land here, never ReaderAlreadyInUse.
                } catch {
                    XCTFail("attempt \(attempt): expected NFCNotSupported, got \(error)")
                }
            }
        }
    }
#endif
