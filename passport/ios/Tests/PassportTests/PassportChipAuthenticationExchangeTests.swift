import Foundation
import XCTest
@testable import PassportSDK

final class PassportChipAuthenticationExchangeTests: XCTestCase {
  private enum RelayFailure: Error { case unavailable }

  func testTerminalReceivesExactDG14AndItsChallengeIsUnchanged() async throws {
    let dg14 = Data([0, 0x6e, 0xff, 0x7f, 0, 0x81])
    let expected = PassportChipAuthenticationChallenge(
      protocolOID: "0.4.0.127.0.7.2.2.3.2.2", keyID: 255,
      terminalPublicKey: Data([0, 4, 0xff, 0]), protectedCommand: Data([0x0c, 0xb0, 0, 0, 0x97, 1, 0]))
    let actual = try await PassportChipAuthenticationRelay.exchange(dg14: dg14) { received in
      XCTAssertEqual(received, dg14)
      return expected
    }
    XCTAssertEqual(actual, expected)
  }

  func testRelayFailureCannotBecomeAnEmptyChallenge() async throws {
    do {
      _ = try await PassportChipAuthenticationRelay.exchange(dg14: Data([0x6e])) { _ in
        throw RelayFailure.unavailable
      }
      XCTFail("A failed terminal must stop the read")
    } catch RelayFailure.unavailable {}
  }

  func testAlreadyCancelledRelayDoesNotContactTheTerminal() async throws {
    let work = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await PassportChipAuthenticationRelay.exchange(dg14: Data([0x6e])) { _ in
        XCTFail("Cancelled work must not contact the remote terminal")
        throw RelayFailure.unavailable
      }
    }
    do { _ = try await work.value; XCTFail("Cancellation must propagate") }
    catch is CancellationError {}
  }

  func testCancellationWhileTerminalReturnsCannotReleaseAChallengeToTheChip() async throws {
    let work = Task {
      try await PassportChipAuthenticationRelay.exchange(dg14: Data([0x6e])) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return PassportChipAuthenticationChallenge(
          protocolOID: "synthetic", keyID: nil, terminalPublicKey: Data([1]), protectedCommand: Data([2]))
      }
    }
    do { _ = try await work.value; XCTFail("A cancelled read must not deliver the challenge") }
    catch is CancellationError {}
  }
}
