#if os(iOS)
  import Foundation
  import XCTest
  @testable import PassportSDK
  @testable import PassportNFC

  final class PassportChipAuthenticationRelayTests: XCTestCase {
    private enum RelayFailure: Error { case unavailable }

    func testRelaysExactDG14AndChallengeWithoutTransformingProtectedBytes() async throws {
      let dg14: [UInt8] = [0, 0x6e, 0xff, 0x7f, 0, 0x81]
      for keyID: Int? in [nil, 0, 255] {
        let challenge = PassportChipAuthenticationChallenge(
          protocolOID: "0.4.0.127.0.7.2.2.3.2.2", keyID: keyID,
          terminalPublicKey: Data([0, 4, 0xff, 0]), protectedCommand: Data([0x0c, 0xb0, 0, 0, 0x97, 1, 0]))
        let terminal = PassportChipAuthenticationTerminalAdapter.terminal { received in
          XCTAssertEqual(received, Data(dg14))
          return challenge
        }
        let relayed = try await terminal(dg14)
        XCTAssertEqual(relayed.protocolOID, challenge.protocolOID)
        XCTAssertEqual(relayed.keyID, keyID)
        XCTAssertEqual(relayed.terminalPublicKey, Array(challenge.terminalPublicKey))
        XCTAssertEqual(relayed.protectedCommand, Array(challenge.protectedCommand))
      }
    }

    func testRelayFailureCannotBecomeAnEmptyChallenge() async throws {
      let terminal = PassportChipAuthenticationTerminalAdapter.terminal { _ in throw RelayFailure.unavailable }
      do { _ = try await terminal([0x6e]); XCTFail("A failed terminal must stop the read") }
      catch RelayFailure.unavailable {}
    }

    func testAlreadyCancelledRelayDoesNotContactTheTerminal() async throws {
      let terminal = PassportChipAuthenticationTerminalAdapter.terminal { _ in
        XCTFail("Cancelled work must not contact the remote terminal")
        throw RelayFailure.unavailable
      }
      let work = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await terminal([0x6e])
      }
      do { _ = try await work.value; XCTFail("Cancellation must propagate") }
      catch is CancellationError {}
    }

    func testCancellationWhileTerminalReturnsCannotReleaseAChallengeToTheChip() async throws {
      let terminal = PassportChipAuthenticationTerminalAdapter.terminal { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return PassportChipAuthenticationChallenge(
          protocolOID: "synthetic", keyID: nil, terminalPublicKey: Data([1]), protectedCommand: Data([2]))
      }
      let work = Task { try await terminal([0x6e]) }
      do { _ = try await work.value; XCTFail("A cancelled read must not deliver the challenge") }
      catch is CancellationError {}
    }
  }
#endif
