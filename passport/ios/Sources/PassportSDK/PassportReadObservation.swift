import Foundation

/// Independent protocol observations, not an identity or enrollment decision.
public enum PassportProtocolObservation: String, Codable, Sendable {
  case notPerformed, succeeded, failed
}

public enum PassportReadFailure: String, Error, Codable, Sendable {
  case unsupported, cancelled, busy, invalidAccessKey, invalidChallenge
  case trustAnchorsUnavailable, trustAnchorNotFound, dataIntegrityFailure
  case connectionLost, multipleTags, invalidTag, readFailed
  case activeAuthenticationFailed, chipAuthenticationFailed
}

/// NFC-04 and RFC-0002 §4.2: a chip that fails Active or Chip Authentication is refused. A protocol
/// the chip did not run is not a failure; a failed proof cannot be returned beside the evidence,
/// because that is a silent downgrade to passive-only authentication.
package enum PassportChipAuthenticity {
  package static func require(
    activeAuthentication: PassportProtocolObservation,
    chipAuthentication: PassportProtocolObservation
  ) throws {
    if activeAuthentication == .failed { throw PassportReadFailure.activeAuthenticationFailed }
    if chipAuthentication == .failed { throw PassportReadFailure.chipAuthenticationFailed }
  }
}

/// Structured progress; the host supplies the text for Apple's NFC sheet.
public enum PassportReadEvent: Equatable, Sendable {
  case presenting
  case authenticating(progress: Int)
  case reading(group: String, progress: Int)
  case activeAuthentication
  case transportFinishing
  case transportComplete
  case passiveAuthentication
  case failure(PassportReadFailure)
}

/// Captured chip evidence. No ambient trust store, server wire format, expiry verdict or persistence.
/// Original DG2 and its embedded encoded portrait stay separate from non-image evidence.
public struct PassportReadObservation: Sendable {
  /// Closed reader diagnostic fields; absent on reads saved before diagnostic capture existed.
  public var paceFailure: PassportPACEFailure? = nil
  public let documentNumber: String
  public let surname: String
  public let givenNames: String
  public let nationality: String
  public let issuingState: String
  public let birthDateYYMMDD: String
  public let expiryDateYYMMDD: String
  public let sex: String
  public let personalNumber: String?
  public let dateOfIssue: String?
  public let issuingAuthority: String?
  public let placeOfBirth: String?
  public let basicAccessControl: PassportProtocolObservation
  public let pace: PassportProtocolObservation
  public let activeAuthentication: PassportProtocolObservation
  public let chipAuthentication: PassportProtocolObservation
  public let countrySigningChain: PassportProtocolObservation
  public let documentSignature: PassportProtocolObservation
  public let dataGroupHashes: PassportProtocolObservation
  public let documentSigningCertificateDER: Data?
  public let activeAuthenticationChallenge: Data?
  public let activeAuthenticationSignature: Data?
  public let securityObject: Data
  public let dataGroups: [String: Data]
  public let declaredDataGroups: [String]
  public let dg2: Data?
  /// Original JPEG/JPEG2000 bytes extracted from the SOD-bound DG2, without re-encoding.
  public let portrait: Data?
  /// The SOD's own hash of the whole DG2 file (tag and length included), lowercase hex, present
  /// only when the read DG2 matched it. A face comparison against `portrait` names this digest, so
  /// a verifier holding the SOD can tell which portrait the face was compared with, without DG2.
  public let dg2Digest: String?
  /// The data-group hash algorithm the SOD names for `dg2Digest`: `SHA-1`, `SHA-256`, `SHA-384`
  /// or `SHA-512`.
  public let dg2DigestAlgorithm: String?
  /// The chip's raw answer, data then SW1 SW2, to the command a remote Chip Authentication
  /// terminal protected under the keys it agreed with the chip. Only that terminal can verify it.
  public let chipAuthenticationResponse: Data?

  package init(
    paceFailure: PassportPACEFailure? = nil,
    documentNumber: String,
    surname: String,
    givenNames: String,
    nationality: String,
    issuingState: String,
    birthDateYYMMDD: String,
    expiryDateYYMMDD: String,
    sex: String,
    personalNumber: String?,
    dateOfIssue: String?,
    issuingAuthority: String?,
    placeOfBirth: String?,
    basicAccessControl: PassportProtocolObservation,
    pace: PassportProtocolObservation,
    activeAuthentication: PassportProtocolObservation,
    chipAuthentication: PassportProtocolObservation,
    countrySigningChain: PassportProtocolObservation,
    documentSignature: PassportProtocolObservation,
    dataGroupHashes: PassportProtocolObservation,
    documentSigningCertificateDER: Data?,
    activeAuthenticationChallenge: Data?,
    activeAuthenticationSignature: Data?,
    securityObject: Data,
    dataGroups: [String: Data],
    declaredDataGroups: [String],
    dg2: Data?,
    portrait: Data?,
    dg2Digest: String?,
    dg2DigestAlgorithm: String?,
    chipAuthenticationResponse: Data?
  ) {
    self.paceFailure = paceFailure
    self.documentNumber = documentNumber
    self.surname = surname
    self.givenNames = givenNames
    self.nationality = nationality
    self.issuingState = issuingState
    self.birthDateYYMMDD = birthDateYYMMDD
    self.expiryDateYYMMDD = expiryDateYYMMDD
    self.sex = sex
    self.personalNumber = personalNumber
    self.dateOfIssue = dateOfIssue
    self.issuingAuthority = issuingAuthority
    self.placeOfBirth = placeOfBirth
    self.basicAccessControl = basicAccessControl
    self.pace = pace
    self.activeAuthentication = activeAuthentication
    self.chipAuthentication = chipAuthentication
    self.countrySigningChain = countrySigningChain
    self.documentSignature = documentSignature
    self.dataGroupHashes = dataGroupHashes
    self.documentSigningCertificateDER = documentSigningCertificateDER
    self.activeAuthenticationChallenge = activeAuthenticationChallenge
    self.activeAuthenticationSignature = activeAuthenticationSignature
    self.securityObject = securityObject
    self.dataGroups = dataGroups
    self.declaredDataGroups = declaredDataGroups
    self.dg2 = dg2
    self.portrait = portrait
    self.dg2Digest = dg2Digest
    self.dg2DigestAlgorithm = dg2DigestAlgorithm
    self.chipAuthenticationResponse = chipAuthenticationResponse
  }
}

/// A remote Chip Authentication terminal's challenge: the protocol and key to agree with, the
/// terminal's ephemeral public key, and one command protected under keys only the chip and the
/// terminal can derive. The reader relays it and keeps the chip's answer.
public struct PassportChipAuthenticationChallenge: Sendable, Equatable {
  public let protocolOID: String
  public let keyID: Int?
  public let terminalPublicKey: Data
  public let protectedCommand: Data

  public init(protocolOID: String, keyID: Int?, terminalPublicKey: Data, protectedCommand: Data) {
    self.protocolOID = protocolOID
    self.keyID = keyID
    self.terminalPublicKey = terminalPublicKey
    self.protectedCommand = protectedCommand
  }
}

/// The hash algorithm a data-group digest of this many hex characters was made with, among the
/// four an SOD may name for the portrait binding. SHA-224 and anything else has no name here.
package enum PassportDigestAlgorithm {
  package static func name(hexLength: Int) -> String? {
    switch hexLength {
    case 40: "SHA-1"
    case 64: "SHA-256"
    case 96: "SHA-384"
    case 128: "SHA-512"
    default: nil
    }
  }
}

/// Operational protocol metadata only. Never carries an MRZ, key, APDU body or native error text.
public struct PassportPACEFailure: Codable, Sendable {
  public let stage: String
  public let code: String
  public let statusWord: Int?

  package init(stage: String, code: String, statusWord: Int?) {
    self.stage = stage
    self.code = code
    self.statusWord = statusWord
  }
}
