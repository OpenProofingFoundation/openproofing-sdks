#if os(iOS) && canImport(DeviceCheck)
import DeviceCheck
#endif
import Foundation
import KenshikiOperationBinding
import Security

public struct PulsePassportRegistrationConfiguration: Sendable {
    public let baseURL: URL
    public let appAttestEnvironment: String?
    public let applicationIdentifier: String?
    public let additionalHeaders: [String: String]
    public init(baseURL: URL, appAttestEnvironment: String?, applicationIdentifier: String?, additionalHeaders:[String:String] = [:]) {self.additionalHeaders=additionalHeaders;self.baseURL=baseURL;self.appAttestEnvironment=appAttestEnvironment;self.applicationIdentifier=applicationIdentifier}

}

public struct PulsePassportCredentials: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Equatable, Sendable { case appAttest }
    public let installationID: String
    public let clientInstallationID: String
    public let appAttestKeyID: String?
    public let token: String
    public let expiresAt: Date?
    public let backendBaseURL: URL?
    public let mode: Mode?
    public let appAttestEnvironment: String?
    public init(installationID: String, clientInstallationID: String, appAttestKeyID: String?, token: String, expiresAt: Date?, backendBaseURL: URL?, mode: Mode?, appAttestEnvironment: String?) {self.installationID=installationID;self.clientInstallationID=clientInstallationID;self.appAttestKeyID=appAttestKeyID;self.token=token;self.expiresAt=expiresAt;self.backendBaseURL=backendBaseURL;self.mode=mode;self.appAttestEnvironment=appAttestEnvironment}

}

public struct PulsePassportAppMetadata: Codable, Equatable, Sendable {
    public let platform: String
    public let appVersion: String
    public let buildNumber: String
    public let sdkVersion: String
    public let locale: String?
    public init(platform: String, appVersion: String, buildNumber: String, sdkVersion: String, locale: String?) {self.platform=platform;self.appVersion=appVersion;self.buildNumber=buildNumber;self.sdkVersion=sdkVersion;self.locale=locale}

}

public struct PulsePassportDeviceMetadata: Codable, Equatable, Sendable {
    public let deviceClass: String
    public let osMajorVersion: Int
    public let modelClass: String
    public init(deviceClass: String, osMajorVersion: Int, modelClass: String) {self.deviceClass=deviceClass;self.osMajorVersion=osMajorVersion;self.modelClass=modelClass}

}

public protocol PulseRegistrationUnknownKeyFailure: Error {var isUnknownRegisteredKey:Bool {get}}

struct PulseRegistrationHTTPFailure: PulseRegistrationUnknownKeyFailure, Sendable {
    var isUnknownRegisteredKey:Bool {unknownKey}
    public let status: Int
    public let unknownKey: Bool
}


public enum PulsePassportRegistrationFailure:Error,Sendable {case configuration,credentials,unsupported,invalidResponse}
