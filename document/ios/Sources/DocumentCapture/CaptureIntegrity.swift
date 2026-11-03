import CryptoKit
import Foundation

public enum CaptureIntegrityError: Error, Sendable {
  case integrityVerificationFailed
}

public enum CaptureArtifactIntegrity {
  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
