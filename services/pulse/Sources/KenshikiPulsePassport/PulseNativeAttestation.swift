import Foundation

/// The host's installation for native attested submissions: its bearer, and an App Attest
/// assertion over an exact client-data hash the client computed. The host's key custody signs;
/// the client decides what is signed.
/// The installationToken seam must read and validate current captured identity without enrolling.
/// Shared registration supplies this contract; a host injecting attestation owns the same fence.
public struct PulseNativeAttestation: Sendable {
  public let installationToken: @Sendable () async throws -> String
  public let assert: @Sendable (_ clientDataHash: Data) async throws -> PulseAppAttestAssertion
  public let recoverInstallationToken: (@Sendable () async throws -> String)?
  public init(installationToken: @escaping @Sendable () async throws -> String,
              assert: @escaping @Sendable (_ clientDataHash: Data) async throws -> PulseAppAttestAssertion,
              recoverInstallationToken: (@Sendable () async throws -> String)? = nil) {
    self.installationToken = installationToken
    self.assert = assert
    self.recoverInstallationToken = recoverInstallationToken
  }
}
