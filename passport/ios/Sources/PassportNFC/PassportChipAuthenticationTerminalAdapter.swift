import Foundation
import PassportSDK

#if os(iOS)
  @preconcurrency import NFCPassportReader

  /// Preserves the exact neutral challenge bytes when adapting the optional remote terminal.
  enum PassportChipAuthenticationTerminalAdapter {
    static func terminal(
      _ relay: @escaping @Sendable (Data) async throws -> PassportChipAuthenticationChallenge
    ) -> ChipAuthenticationTerminal {
      { @Sendable (dg14: [UInt8]) async throws -> ChipAuthenticationTerminalChallenge in
        let challenge = try await PassportChipAuthenticationRelay.exchange(dg14: Data(dg14), relay: relay)
        return ChipAuthenticationTerminalChallenge(
          protocolOID: challenge.protocolOID, keyID: challenge.keyID,
          terminalPublicKey: Array(challenge.terminalPublicKey),
          protectedCommand: Array(challenge.protectedCommand))
      }
    }
  }
#endif
