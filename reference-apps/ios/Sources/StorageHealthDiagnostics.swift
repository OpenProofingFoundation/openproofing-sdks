#if DEBUG
import CryptoKit
import Foundation
import KenshikiProtectedStorage

/// Closed reason codes only. Arbitrary error descriptions, paths and retained contents never export.
struct StorageHealthFailure: Codable, Equatable {
    let family: String
    let code: String
    let status: Int32?

    init(_ error: any Error) {
        var family = "unknown"
        var code = "unclassified"
        var status: Int32?
        switch error {
        case let failure as ProtectedSQLiteError:
            family = "sqlite"
            switch failure {
            case .invalidLocation: code = "invalidLocation"
            case .unavailable(let value): code = "unavailable"; status = value
            case .cipherUnavailable: code = "cipherUnavailable"
            case .invalidKey: code = "invalidKey"
            case .migrationRequired: code = "migrationRequired"
            case .destinationExists: code = "destinationExists"
            case .migrationConflict: code = "migrationConflict"
            case .unfinalizedStatements: code = "unfinalizedStatements"
            }
        case let failure as ProtectedStoreKeyError:
            family = "keyCustody"
            switch failure {
            case .invalidIdentity: code = "invalidIdentity"
            case .invalidEnvelope: code = "invalidEnvelope"
            case .invalidKeySize: code = "invalidKeySize"
            case .missingKey: code = "missingKey"
            case .hardwareUnavailable: code = "hardwareUnavailable"
            case .keyAlreadyExists: code = "keyAlreadyExists"
            case .keychainFailure(let value): code = "keychainFailure"; status = value
            }
        case let failure as ProtectedStoreLifecycleError:
            family = "lifecycle"
            switch failure {
            case .staleHandle: code = "staleHandle"
            case .erasurePending: code = "erasurePending"
            case .invalidLifecycle: code = "invalidLifecycle"
            case .nestedAdmission: code = "nestedAdmission"
            case .ioFailure(let value): code = "ioFailure"; status = value
            }
        case let failure as PassportCaptureStorageFailure:
            family = "passportRecord"
            switch failure {
            case .invalidCapture: code = "invalidCapture"
            case .unsupportedVersion: code = "unsupportedVersion"
            case .unavailable: code = "unavailable"
            }
        case let failure as FaceWorkflowStorageFailure:
            family = "comparisonRecord"
            switch failure {
            case .invalidRecord: code = "invalidRecord"
            case .missingRecord: code = "missingRecord"
            case .conflict: code = "conflict"
            case .capacity: code = "capacity"
            case .unavailable: code = "unavailable"
            }
        case let failure as DecodingError:
            family = "decoding"
            switch failure {
            case .typeMismatch: code = "typeMismatch"
            case .valueNotFound: code = "valueNotFound"
            case .keyNotFound: code = "keyNotFound"
            case .dataCorrupted: code = "dataCorrupted"
            @unknown default: code = "unclassified"
            }
        case let failure as POSIXError:
            family = "posix"; code = "ioFailure"; status = failure.code.rawValue
        case let failure as CocoaError:
            family = "cocoa"; code = "ioFailure"; status = Int32(clamping: failure.code.rawValue)
        case is CryptoKitError:
            family = "cryptography"; code = "operationFailed"
        case is CancellationError:
            family = "task"; code = "cancelled"
        default:
            let value = error as NSError
            if value.domain == NSOSStatusErrorDomain {
                family = "osStatus"; code = "operationFailed"; status = Int32(clamping: value.code)
            }
        }
        self.family = family
        self.code = code
        self.status = status
    }
}

struct StorageHealthReport: Codable, Equatable {
    let schemaVersion: Int
    var canonicalizationRequired: Bool?
    // Inferred from the unchanged core URL equality policy; no old database/key operation executes.
    var rawLocationPolicyMismatch: Bool?
    var stage: PassportStorageStartupStage
    var failure: StorageHealthFailure?
    var sequence: UInt64
}

/// Debug diagnostics remain available even when protected store construction or readback fails.
@MainActor final class StorageHealthDiagnostics {
    private(set) var report = StorageHealthReport(schemaVersion: 1, stage: .constructing, sequence: 0)
    private(set) var exportFailure: StorageHealthFailure?
    private let write: (Data) throws -> Void

    init(write: @escaping (Data) throws -> Void) { self.write = write }

    static func live() throws -> StorageHealthDiagnostics {
        let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).resolvingSymlinksInPath()
            .appendingPathComponent("KenshikiDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(values)
        let destination = directory.appendingPathComponent("storage-health.json")
        return StorageHealthDiagnostics { bytes in
            try bytes.write(to: destination, options: [.atomic, .completeFileProtection])
        }
    }

    func observeTrustedRoot(canonicalizationRequired: Bool) {
        report.canonicalizationRequired = canonicalizationRequired
        report.rawLocationPolicyMismatch = canonicalizationRequired
        publish()
    }

    func record(stage: PassportStorageStartupStage, error: (any Error)? = nil) {
        report.stage = stage
        report.failure = error.map(StorageHealthFailure.init)
        publish()
    }

    private func publish() {
        report.sequence += 1
        do {
            let bytes = try JSONEncoder().encode(report)
            try write(bytes)
            exportFailure = nil
        } catch { exportFailure = StorageHealthFailure(error) }
    }
}
#endif
