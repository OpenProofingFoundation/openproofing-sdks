import Foundation
import CryptoKit

public struct PulsePassportChipProof: Sendable, Equatable {
  public let securityObject: Data
  public let documentSigningCertificate: Data
  /// ICAO file name (`DG1`, `DG14`, …) to the file's bytes, exactly as read.
  public let dataGroups: [String: Data]
  public let activeAuthenticationChallenge: Data?
  public let activeAuthenticationSignature: Data?

  public init(securityObject: Data, documentSigningCertificate: Data, dataGroups: [String: Data],
              activeAuthenticationChallenge: Data?, activeAuthenticationSignature: Data?) {
    self.securityObject = securityObject
    self.documentSigningCertificate = documentSigningCertificate
    self.dataGroups = dataGroups
    self.activeAuthenticationChallenge = activeAuthenticationChallenge
    self.activeAuthenticationSignature = activeAuthenticationSignature
  }

  /// The groups the wire carries: `DG1`–`DG16` except `DG2`.
  public var sentDataGroups: [String: Data] {
    dataGroups.filter { name, _ in
      name != "DG2" && name.range(of: "^DG([1-9]|1[0-6])$", options: .regularExpression) != nil
    }
  }
}

/// A device-owned passport session: `POST /identity/sessions`.
public struct PulsePassportSession: Sendable, Equatable {
  public let sessionID: String
  public let sessionNonce: String
  public let expiresAt: String

  /// Public so a host can keep one ceremony's session across a retry rather than open another.
  public init(sessionID: String, sessionNonce: String, expiresAt: String) {
    self.sessionID = sessionID
    self.sessionNonce = sessionNonce
    self.expiresAt = expiresAt
  }
}

/// The passport nonce the chip's Active Authentication signs over: `POST /passport/nonce`.
public struct PulsePassportNonce: Sendable, Equatable {
  public let sessionID: String
  public let nonceID: String
  public let nonce: String
  public let expiresAt: String
  public let iacKeyID: String
  public let workflow: String
  public let payloadCommitmentHash: String?

  /// Allows the host to retain a nonce across an NFC retry. The host must establish that it
  /// remains unexpired and unconsumed; an uncertain server reply does not establish either.
  public init(sessionID: String, nonceID: String, nonce: String, expiresAt: String, iacKeyID: String,
              workflow: String, payloadCommitmentHash: String?) {
    self.sessionID = sessionID
    self.nonceID = nonceID
    self.nonce = nonce
    self.expiresAt = expiresAt
    self.iacKeyID = iacKeyID
    self.workflow = workflow
    self.payloadCommitmentHash = payloadCommitmentHash
  }

  /// The eight bytes the chip signs under Active Authentication: the first eight bytes of
  /// SHA-256(UTF-8 nonce). The Worker recomputes them and compares in constant time, so a read made
  /// without them can never be verified afterwards.
  public var activeAuthenticationChallenge: Data {
    Data(SHA256.hash(data: Data(nonce.utf8)).prefix(8))
  }
}

/// The server half of Chip Authentication (`pulse.passport-ca.v1`, `POST /passport/chip-authentication`):
/// the server's ephemeral key for the chip and one command protected under the keys only the
/// chip and the server can agree. The phone relays both to the chip and returns the chip's raw answer.
public struct PulseChipAuthenticationChallenge: Sendable, Equatable {
  public init(protocolName:String,caProtocolOID:String,keyID:Int?,ephemeralPublicKey:Data,protectedCommand:Data) { self.protocolName=protocolName;self.caProtocolOID=caProtocolOID;self.keyID=keyID;self.ephemeralPublicKey=ephemeralPublicKey;self.protectedCommand=protectedCommand }
  public let protocolName: String
  public let caProtocolOID: String
  public let keyID: Int?
  public let ephemeralPublicKey: Data
  public let protectedCommand: Data
}

/// The Worker's account of a chip read.
public struct PulsePassportVerification: Sendable, Equatable {
  public enum Status: String, Codable, Sendable { case verified, failed }
  public let status: Status
  public let validator: String
  public let failureReason: String?
  public let activeAuthentication: Bool
  public let chipAuthentication: Bool
  public let documentExpired: Bool?
  public let trustBundleVersion: String?
  public let assurance: String?
  /// The holder-binding token for this installation’s recorded verification.
  /// The phone retains it for later holder-bound requests.
  public let holderBinding: String?
  public let validationReport: PulsePassportValidationReport?

  public init(status: Status, validator: String, failureReason: String?, activeAuthentication: Bool,
       chipAuthentication: Bool, documentExpired: Bool?, trustBundleVersion: String?, assurance: String?,
       holderBinding: String?, validationReport: PulsePassportValidationReport? = nil) {
    self.status = status; self.validator = validator; self.failureReason = failureReason
    self.activeAuthentication = activeAuthentication; self.chipAuthentication = chipAuthentication
    self.documentExpired = documentExpired; self.trustBundleVersion = trustBundleVersion
    self.assurance = assurance; self.holderBinding = holderBinding; self.validationReport = validationReport
  }
}

public enum PulsePassportFailure: String, Error, Sendable {
  case invalidRequest, unauthorized, forbidden, conflict, rateLimited, unavailable, timedOut
  case invalidResponse
  /// The proof needs Chip Authentication and the Worker has no key seed configured.
  case chipAuthenticationUnavailable
  /// DG14 declares a key or suite the Worker cannot be a terminal for.
  case chipAuthenticationUnsupported
  /// The App Attest counter did not advance: another submission used it first. Re-signing fixes it.
  case assertionReused
  /// The proof lacks a member the wire requires (the Security Object or the signing certificate).
  case incompleteProof
  /// A single-use server challenge expired before the request that carried it arrived.
  case challengeExpired
  /// A face attempt id the Worker has already recorded an outcome for.
  case faceAttemptRecorded
  /// No proved passport verification exists for the installation to anchor a face attempt to.
  case facePassportUnbound
}

/// The passport chain against the Worker, in the order the chip read requires: a device-owned
/// session, then the nonce whose digest the chip signs during the read, then — for a chip that
/// declares Chip Authentication — the server's challenge to relay to the chip, then the
/// submission: `POST /passport/verify` with the installation bearer and an App Attest
/// assertion over SHA-256(`pulse:passport-verify:v1` || 0x00 || payload_json).
///
/// DG2 is never in the payload. The portrait stays on the phone; the face result belongs in the
/// face envelope, bound to the SOD-authenticated portrait hash.
