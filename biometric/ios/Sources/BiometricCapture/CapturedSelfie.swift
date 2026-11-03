import CryptoKit
import Foundation

/// Exact encoded native AR-frame snapshot and its original admission receipt.
/// This PNG is the existing camera adapter's rendered snapshot, not an AVCapturePhoto original.
public struct CapturedSelfie: Sendable {
  public let id: UUID
  public let encodedPNG: Data
  public let admissionReceipt: SelfieAdmissionReceipt
  public var sha256: String {
    SHA256.hash(data: encodedPNG).map { String(format: "%02x", $0) }.joined()
  }
  init(encodedPNG: Data, admissionReceipt: SelfieAdmissionReceipt) {
    id = UUID()
    self.encodedPNG = encodedPNG
    self.admissionReceipt = admissionReceipt
  }
}
