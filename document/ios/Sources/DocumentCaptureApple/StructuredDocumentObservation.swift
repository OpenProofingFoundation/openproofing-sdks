import Foundation

/// Derived reader output, never a document-authentication verdict.
public struct StructuredDocumentObservation: Codable, Sendable, Equatable {
  public enum Status: String, Codable, Sendable { case complete, incomplete, failed }
  public let sourceSHA256: String
  public let status: Status
  public let processingStatus: String
  public var providerArtifactSHA256: String?
  public let provider: String
  public let implementationVersion: String
  public let country: String?
  public let region: String?
  public let documentType: String?
  /// Exact field strings returned by the provider, including date diagnostics.
  public let rawFields: [String: String]
  public let issues: [String]

  public init(
    sourceSHA256: String, status: Status, processingStatus: String,
    provider: String, implementationVersion: String,
    country: String? = nil, region: String? = nil, documentType: String? = nil,
    rawFields: [String: String] = [:], issues: [String] = []
  ) {
    self.sourceSHA256 = sourceSHA256
    self.status = status
    self.processingStatus = processingStatus
    self.provider = provider
    self.implementationVersion = implementationVersion
    self.country = country
    self.region = region
    self.documentType = documentType
    self.rawFields = rawFields
    self.issues = issues
  }

  /// Explicit representation mappings only. Raw values remain unchanged.
  public var normalizedFields: [String: String] {
    var fields = rawFields.filter { !$0.key.contains(".") }
    if let value = fields["sex"] {
      fields["sex"] = ["MALE": "M", "FEMALE": "F"][value.uppercased()] ?? value
    }
    if fields["nationality"]?.uppercased() == "AMERICAN" { fields["nationality"] = "USA" }
    return fields
  }
}
