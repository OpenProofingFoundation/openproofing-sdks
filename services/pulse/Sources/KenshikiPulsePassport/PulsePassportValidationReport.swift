import Foundation

public struct PulsePassportValidationReport: Codable, Equatable, Sendable {
    public enum Assurance: String, Codable, Sendable {
        case chipAuthenticated = "chip_authenticated"
        case passiveAuthenticationOnly = "passive_authentication_only"
        case unverified
    }
    public let result: PulsePassportVerification.Status
    public let validator: String
    public let receiptId: String?
    public let sodVerified: Bool
    public let dscVerified: Bool
    public let cscaVerified: Bool
    public let dataGroupHashesVerified: Bool
    public let chipAuthenticated: Bool
    public let activeAuthentication: Bool
    public let chipAuthentication: Bool
    public let crlChecked: Bool
    public let documentExpired: Bool?
    public let failureReason: String?
    public let trustBundleVersion: String?
    public let trustManifestSha256: String?
    public let assurance: Assurance

    public init(result: PulsePassportVerification.Status, validator: String, receiptId: String?, sodVerified: Bool, dscVerified: Bool, cscaVerified: Bool, dataGroupHashesVerified: Bool, chipAuthenticated: Bool, activeAuthentication: Bool, chipAuthentication: Bool, crlChecked: Bool, documentExpired: Bool?, failureReason: String?, trustBundleVersion: String?, trustManifestSha256: String?, assurance: Assurance) {
        self.result = result
        self.validator = validator
        self.receiptId = receiptId
        self.sodVerified = sodVerified
        self.dscVerified = dscVerified
        self.cscaVerified = cscaVerified
        self.dataGroupHashesVerified = dataGroupHashesVerified
        self.chipAuthenticated = chipAuthenticated
        self.activeAuthentication = activeAuthentication
        self.chipAuthentication = chipAuthentication
        self.crlChecked = crlChecked
        self.documentExpired = documentExpired
        self.failureReason = failureReason
        self.trustBundleVersion = trustBundleVersion
        self.trustManifestSha256 = trustManifestSha256
        self.assurance = assurance
    }

    public func validate() throws {
        guard !validator.isEmpty, validator.utf8.count <= 256,
              receiptId.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
            throw PulsePassportFailure.invalidResponse
        }
        if result == .failed {
            guard assurance == .unverified else { throw PulsePassportFailure.invalidResponse }
            return
        }
        guard failureReason == nil, sodVerified, dscVerified, cscaVerified, dataGroupHashesVerified, crlChecked,
              documentExpired == false,
              chipAuthenticated == (activeAuthentication || chipAuthentication),
              assurance == (chipAuthenticated ? .chipAuthenticated : .passiveAuthenticationOnly),
              let version = trustBundleVersion, !version.isEmpty, version.utf8.count <= 256,
              let manifest = trustManifestSha256, manifest.utf8.count == 64,
              manifest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PulsePassportFailure.invalidResponse
        }
    }

    public var exportObject: [String: Any] {
        var value: [String: Any] = ["result": result.rawValue, "validator": validator,
            "sodVerified": sodVerified, "dscVerified": dscVerified, "cscaVerified": cscaVerified,
            "dataGroupHashesVerified": dataGroupHashesVerified, "chipAuthenticated": chipAuthenticated,
            "activeAuthentication": activeAuthentication, "chipAuthentication": chipAuthentication,
            "crlChecked": crlChecked, "assurance": assurance.rawValue]
        value["receiptId"] = receiptId; value["documentExpired"] = documentExpired
        value["failureReason"] = failureReason; value["trustBundleVersion"] = trustBundleVersion
        value["trustManifestSha256"] = trustManifestSha256
        return value
    }
}

