import Foundation

public enum SensorEvidenceContractError: Error, Equatable, Sendable {
  case invalid(String)
}

enum SensorContractChecks {
  static func require(_ condition: Bool, _ field: String) throws {
    guard condition else { throw SensorEvidenceContractError.invalid(field) }
  }

  static func identifier(_ value: String, _ field: String) throws {
    try require(!value.isEmpty && value.utf8.count <= 256, field)
    try require(
      !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, field)
  }
}

/// A record identity has one immutable commitment throughout a composed admitted value.
struct SensorArtifactCommitments {
  private var digests: [String: String] = [:]

  mutating func include(_ references: [SensorArtifactReference]) throws {
    for reference in references {
      if let prior = digests[reference.recordID] {
        try SensorContractChecks.require(prior == reference.sha256, "conflictingRecordDigest")
      }
      digests[reference.recordID] = reference.sha256
    }
  }
}

/// A caller-owned immutable record address and exact-byte SHA-256 commitment.
/// Construction validates shape; it does not read storage or verify acquisition authenticity.
public struct SensorArtifactReference: Equatable, Hashable, Sendable {
  public let recordID: String
  public let sha256: String

  public init(recordID: String, sha256: String) throws {
    try SensorContractChecks.identifier(recordID, "recordID")
    try SensorContractChecks.require(
      sha256.utf8.count == 64
        && sha256.utf8.allSatisfy {
          (48...57).contains($0) || (97...102).contains($0)
        }, "sha256")
    self.recordID = recordID
    self.sha256 = sha256
  }
}

public enum SensorDerivationInputRole: String, Sendable {
  case supporting, contradicting, rejected, context, omission
}

public enum SensorDerivationExtent: Equatable, Sendable {
  case point(SensorMeasurementTime)
  case interval(SensorEvidenceInterval)
}

public enum SensorDerivationLimitation: String, Sendable {
  case partialInput, unavailableInput, rawSamplesNotRetained, clockAlignmentUncertain
  case calibrationUnavailable, resolutionUnknown, sourceAuthenticityUnverified, methodNotQualified
}

public struct SensorDerivationInput: Equatable, Sendable {
  public let reference: SensorArtifactReference
  public let selector: String
  public let role: SensorDerivationInputRole
  public let reasonCode: String?
  public let extent: SensorDerivationExtent

  public init(
    reference: SensorArtifactReference, selector: String,
    role: SensorDerivationInputRole, extent: SensorDerivationExtent, reasonCode: String? = nil
  ) throws {
    try SensorContractChecks.identifier(selector, "selector")
    if let reasonCode { try SensorContractChecks.identifier(reasonCode, "reasonCode") }
    try SensorContractChecks.require(
      role != .rejected && role != .omission || reasonCode != nil, "inputReason")
    self.reference = reference
    self.selector = selector
    self.role = role
    self.reasonCode = reasonCode
    self.extent = extent
  }
}

/// Ordered complete input manifest, including inputs that decided rejection or abstention.
/// The producer must enumerate every deciding input; this value cannot discover omitted evidence.
public struct SensorDerivationBinding: Equatable, Sendable {
  public static let maximumInputs = 4_096
  public let methodID: String
  public let methodVersion: String
  public let configuration: SensorArtifactReference
  public let inputs: [SensorDerivationInput]
  public let limitations: [SensorDerivationLimitation]

  var artifactReferences: [SensorArtifactReference] {
    [configuration] + inputs.map(\.reference)
  }

  public init(
    methodID: String, methodVersion: String,
    configuration: SensorArtifactReference, inputs: [SensorDerivationInput],
    limitations: [SensorDerivationLimitation]
  ) throws {
    try SensorContractChecks.identifier(methodID, "methodID")
    try SensorContractChecks.identifier(methodVersion, "methodVersion")
    try SensorContractChecks.require(
      !inputs.isEmpty && inputs.count <= Self.maximumInputs, "inputs")
    try SensorContractChecks.require(
      limitations.count <= 8 && Set(limitations.map(\.rawValue)).count == limitations.count,
      "limitations")
    var identities: [String: String] = [configuration.recordID: configuration.sha256]
    var selectorsByRecord: [String: Set<String>] = [:]
    for input in inputs {
      if let prior = identities[input.reference.recordID] {
        try SensorContractChecks.require(prior == input.reference.sha256, "conflictingInputDigest")
      }
      identities[input.reference.recordID] = input.reference.sha256
      // Use the same canonical String equality as the record commitment dictionary.
      // Byte-length prefixes would distinguish canonically equivalent Unicode spellings.
      let inserted = selectorsByRecord[input.reference.recordID, default: []]
        .insert(input.selector).inserted
      try SensorContractChecks.require(inserted, "duplicateInput")
    }
    self.methodID = methodID
    self.methodVersion = methodVersion
    self.configuration = configuration
    self.inputs = inputs
    self.limitations = limitations
  }
}
