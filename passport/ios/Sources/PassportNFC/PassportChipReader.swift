// Responsibility: Coordinates one NFC passport read, verification and observation conversion.
// Control: Requires host trust anchors; remote Chip Authentication answers are judged by the remote terminal.
// App counterpart: PassportChipRead supplies the access key, trust file and server challenge relay.
// Specification: RFC-0002 §§4.2–4.3; capability-evidence-and-assurance-plan §3.12.

import Foundation
import PassportSDK

#if os(iOS)
  import CoreNFC
  @preconcurrency import NFCPassportReader

  /// One operation per instance; cancellation flows into CoreNFC's exactly-once settlement.
  /// Uses the reader's bounded in-session tag-loss recovery, never an app retry timer.
  /// Apple: https://developer.apple.com/documentation/corenfc/nfctagreadersession
  /// https://developer.apple.com/documentation/corenfc/nfctagreadersession/restartpolling()
  @MainActor
  public final class PassportChipReader {
    public enum Availability: String, Sendable { case available, unavailable }
    public static var availability: Availability {
      NFCTagReaderSession.readingAvailable ? .available : .unavailable
    }

    private let trustAnchorsURL: URL
    private var occupied = false

    /// The adopter names its provisioned PEM file. Nothing searches the application bundle.
    public init(trustAnchorsURL: URL) { self.trustAnchorsURL = trustAnchorsURL }

    /// Returns only after transport closes, all three passive-authentication legs succeed, and
    /// neither Active nor Chip Authentication failed (a protocol the chip did not run is not a
    /// failure).
    /// `challenge`, when supplied, is the exact eight bytes to ask the chip to sign. Any server
    /// nonce derivation belongs to the caller's protocol. `displayMessage` must return host text
    /// for every event, so vendor English and diagnostic descriptions cannot escape by fallback.
    ///
    /// `chipAuthenticationTerminal`, when supplied, makes a remote terminal the Chip
    /// Authentication counterpart: it receives the chip's DG14 bytes during the read and returns
    /// its challenge, which the reader relays to the chip as the read's last step. The chip's raw
    /// answer is `chipAuthenticationResponse`; the reader cannot judge it, so `chipAuthentication`
    /// stays `.notPerformed` for this device.
    public func read(
      accessKey: PassportAccessKey,
      challenge: Data?,
      chipAuthenticationTerminal: (@Sendable (Data) async throws -> PassportChipAuthenticationChallenge)? = nil,
      displayMessage: @escaping @Sendable (PassportReadEvent) -> String,
      onEvent: @escaping @Sendable (PassportReadEvent) -> Void = { _ in }
    ) async throws -> PassportReadObservation {
      guard !occupied else { throw PassportReadFailure.busy }
      guard !Task.isCancelled else { throw PassportReadFailure.cancelled }
      guard challenge == nil || challenge?.count == 8 else {
        throw PassportReadFailure.invalidChallenge
      }
      guard Self.availability == .available else { throw PassportReadFailure.unsupported }
      guard trustAnchorsURL.isFileURL,
        let anchors = try? Data(contentsOf: trustAnchorsURL), !anchors.isEmpty
      else { throw PassportReadFailure.trustAnchorsUnavailable }
      occupied = true
      defer { occupied = false }
      let reader = PassportReader(masterListURL: trustAnchorsURL)
      let messageHandler: @Sendable (NFCViewDisplayMessage) -> String? = { message in
        let event = PassportReaderEvents.event(message)
        onEvent(event)
        return displayMessage(event)
      }
      let terminal = chipAuthenticationTerminal.map(PassportChipAuthenticationTerminalAdapter.terminal)
      do {
        let unverified = try await reader.readPassportUnverified(
          mrzKey: accessKey.value,
          tags: [.COM, .DG1, .DG2, .DG11, .DG12, .DG14, .DG15, .SOD],
          aaChallenge: challenge.map(Array.init), skipSecureElements: false,
          chipAuthenticationTerminal: terminal,
          customDisplayMessage: messageHandler)
        onEvent(.transportComplete)
        try Task.checkCancellation()
        onEvent(.passiveAuthentication)
        // The vendor model is not Sendable. The closed transport hands sole ownership to this
        // box; the detached task verifies and converts it to values without sharing it back.
        let model = OwnedPassport(unverified.passport)
        let url = trustAnchorsURL
        let observation = try await Task.detached(priority: .userInitiated) {
          model.value.verifyPassport(masterListURL: url)
          return try PassportObservationMapper.observation(model.value)
        }.value
        try Task.checkCancellation()
        return observation
      } catch {
        throw PassportReaderEvents.failure(error)
      }
    }

    private struct OwnedPassport: @unchecked Sendable {
      let value: NFCPassportModel
      init(_ value: NFCPassportModel) { self.value = value }
    }

  }
#endif
