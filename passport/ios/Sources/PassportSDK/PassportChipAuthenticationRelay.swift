// Responsibility: Adapts the host’s server-terminal challenge to the NFC reader.
// Control: Relays exact DG14/challenge bytes and propagates cancellation; it does not verify the chip’s protected answer.
// App counterpart: PassportChipRead receives these results through PassportChipReader.
// Specification: RFC-0002 §§4.2–4.3; capability-evidence-and-assurance-plan §3.12.

import Foundation

/// Adapts the host's remote terminal without interpreting or changing its cryptographic bytes.
package enum PassportChipAuthenticationRelay {
  package static func exchange(
    dg14: Data,
    relay: @Sendable (Data) async throws -> PassportChipAuthenticationChallenge
  ) async throws -> PassportChipAuthenticationChallenge {
    try Task.checkCancellation()
    let challenge = try await relay(dg14)
    try Task.checkCancellation()
    return challenge
  }

}
