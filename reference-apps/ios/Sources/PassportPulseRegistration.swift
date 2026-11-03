import Foundation
import KenshikiPulsePassport
import KenshikiOperationBinding

typealias PassportPulseRegistration = KenshikiPulsePassport.PulsePassportRegistration
typealias PassportRegistrationSlot = KenshikiPulsePassport.PulsePassportRegistrationSlot
typealias PassportRegistrationStorage = KenshikiPulsePassport.PulsePassportRegistrationStorage
typealias PulseContinuityBackendConfiguration = KenshikiPulsePassport.PulsePassportRegistrationConfiguration
typealias PulseContinuityCredentials = KenshikiPulsePassport.PulsePassportCredentials
typealias PulseContinuityAppMetadata = KenshikiPulsePassport.PulsePassportAppMetadata
typealias PulseContinuityDeviceMetadata = KenshikiPulsePassport.PulsePassportDeviceMetadata

extension PulsePassportRegistration {
    /// Only host namespace, application metadata and resource discovery live in the app.
    @MainActor static func live(in bundle: Bundle = .main) throws -> PulsePassportRegistration {
        guard let raw = bundle.object(forInfoDictionaryKey: "PulsePassportBaseURL") as? String,
              let url = URL(string: raw),
              let environment = bundle.object(forInfoDictionaryKey: "PulsePassportAppAttestEnvironment") as? String,
              let application = bundle.object(forInfoDictionaryKey: "PulsePassportApplicationIdentifier") as? String,
              let identifier = bundle.bundleIdentifier, application == identifier,
              let group = bundle.object(forInfoDictionaryKey: "KenshikiKeychainAccessGroup") as? String,
              !group.contains("$("), !group.isEmpty else { throw PassportServerFailure.configuration }
        let namespace = identifier + ".passport-server." + environment + "." + SealedOperation.sha256(Data(raw.utf8))
        return try .live(baseURL: url, environment: environment, applicationIdentifier: identifier,
            keychainAccessGroup: group, namespace: namespace,
            app: .init(platform: "ios", appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1",
                buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1", sdkVersion: "0.1.0", locale: Locale.current.identifier),
            device: .init(deviceClass: "iPhone", osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, modelClass: "phone"))
    }
}
