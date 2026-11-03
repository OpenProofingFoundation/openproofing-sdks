import Foundation
import CoreFoundation
import CryptoKit

public enum PortraitFailure: String, Error, Sendable {
    case invalidSchema = "invalid_schema"
    case invalidPixels = "invalid_pixels"
    case unsupportedFormat = "unsupported_format"
    case resourceLimit = "resource_limit"
    case integrityFailure = "integrity_failure"
    case bindingMismatch = "binding_mismatch"
    case operationUnavailable = "operation_unavailable"
    case operationReused = "operation_reused"
}

/// Immutable packed pixels. The snapshot owns its bytes independently of caller memory.
public struct PortraitPixels: Sendable {
    public let width: Int
    public let height: Int
    public let format: String
    public let rowStrideBytes: Int
    public let orientation: Int
    public let sha256: String
    private let snapshot: [UInt8]
    public var bytes: [UInt8] { snapshot }

    /// Untrusted raster metadata. Constructing a layout does not validate or own pixels;
    /// `PortraitPixels.init` validates every declared field against the consumed bytes.
    public struct Layout: Sendable {
        public let width: Int
        public let height: Int
        public let format: String
        public let rowStrideBytes: Int
        public let byteLength: Int
        public let orientation: Int

        public init(width: Int, height: Int, format: String, rowStrideBytes: Int,
                    byteLength: Int, orientation: Int) {
            self.width = width
            self.height = height
            self.format = format
            self.rowStrideBytes = rowStrideBytes
            self.byteLength = byteLength
            self.orientation = orientation
        }
    }

    public init(layout: Layout, sha256: String, bytes: [UInt8]) throws {
        let width = layout.width
        let height = layout.height
        let format = layout.format
        let rowStrideBytes = layout.rowStrideBytes
        let byteLength = layout.byteLength
        let orientation = layout.orientation
        let channels: Int
        switch format {
        case "rgb8": channels = 3
        case "gray8": channels = 1
        default: throw PortraitFailure.unsupportedFormat
        }
        guard width > 0, height > 0, rowStrideBytes > 0, byteLength > 0,
              (1...8).contains(orientation) else { throw PortraitFailure.invalidPixels }
        // Validate ceilings before multiplication, hashing or creating the owned snapshot.
        guard width <= 16384, height <= 16384, width <= 67108864 / height
        else { throw PortraitFailure.resourceLimit }
        let row = width * channels
        let size = row * height
        guard size <= 268435456 else { throw PortraitFailure.resourceLimit }
        guard rowStrideBytes == row, byteLength == size, bytes.count == size
        else { throw PortraitFailure.invalidPixels }
        guard Self.isDigest(sha256) else { throw PortraitFailure.invalidSchema }
        let owned = bytes.map { $0 }
        let digest = SHA256.hash(data: Data(owned)).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw PortraitFailure.integrityFailure }
        self.width = width; self.height = height; self.format = format
        self.rowStrideBytes = rowStrideBytes; self.orientation = orientation
        self.sha256 = sha256; self.snapshot = owned
    }

    /// Strict decoded JSON boundary; numbers must be integers, never booleans or floats.
    public static func fromFields(_ fields: [String: Any], bytes: [UInt8]) throws -> PortraitPixels {
        let names: Set<String> = ["width", "height", "format", "rowStrideBytes", "byteLength", "sha256", "orientation"]
        guard Set(fields.keys) == names else { throw PortraitFailure.invalidSchema }
        guard let format = fields["format"] as? String, ["rgb8", "gray8"].contains(format)
        else { throw PortraitFailure.unsupportedFormat }
        let width = try integer(fields["width"])
        let height = try integer(fields["height"])
        let row = try integer(fields["rowStrideBytes"])
        let length = try integer(fields["byteLength"])
        let orientation = try integer(fields["orientation"])
        // Digest syntax is checked after dimensions/layout, matching the shared contract.
        let layout = Layout(width: width, height: height, format: format,
                            rowStrideBytes: row, byteLength: length, orientation: orientation)
        return try PortraitPixels(layout: layout,
                                  sha256: fields["sha256"] as? String ?? "", bytes: bytes)
    }

    private static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              let integer = Int(number.stringValue), integer > 0
        else { throw PortraitFailure.invalidPixels }
        return integer
    }

    fileprivate static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Structural byte/identity binding only; this is not source authenticity or admission.
public struct PortraitBinding: Sendable, Equatable {
    public let fields: [String: String]
    public static let fieldNames: Set<String> = [
        "sessionID", "attemptID", "operationID", "referenceCaptureID", "probeCaptureID",
        "referenceArtifactID", "probeArtifactID", "referenceSourceSHA256", "probeSourceSHA256",
        "referenceSHA256", "probeSHA256", "referenceLineageSHA256", "probeLineageSHA256",
        "artifactManifestSHA256", "preprocessingManifestSHA256"
    ]

    public init(fields: [String: String]) throws {
        guard Set(fields.keys) == Self.fieldNames else { throw PortraitFailure.invalidSchema }
        for (name, content) in fields {
            if name.hasSuffix("SHA256") {
                guard PortraitPixels.isDigest(content) else { throw PortraitFailure.invalidSchema }
            } else {
                guard let identifier = UUID(uuidString: content), identifier.uuidString.lowercased() == content
                else { throw PortraitFailure.invalidSchema }
            }
        }
        self.fields = fields
    }

    public static func fromFields(_ fields: [String: Any]) throws -> PortraitBinding {
        guard fields.values.allSatisfy({ $0 is String }), let strings = fields as? [String: String]
        else { throw PortraitFailure.invalidSchema }
        return try PortraitBinding(fields: strings)
    }

    public func requireMatches(_ completion: PortraitBinding) throws {
        guard self == completion else { throw PortraitFailure.bindingMismatch }
    }
}

public struct ComparisonRequest: Sendable {
    public let binding: PortraitBinding
    public let reference: PortraitPixels
    public let probe: PortraitPixels

    public init(binding: PortraitBinding, reference: PortraitPixels, probe: PortraitPixels) throws {
        guard binding.fields["referenceSHA256"] == reference.sha256,
              binding.fields["probeSHA256"] == probe.sha256 else { throw PortraitFailure.integrityFailure }
        self.binding = binding; self.reference = reference; self.probe = probe
    }
}

/// A model-scoped numerical observation, with exact input binding and no acceptance policy.
public struct BoundComparisonObservation: Sendable {
    public let binding: PortraitBinding
    public let similarity: CosineSimilarity

    public init(binding: PortraitBinding, similarity: CosineSimilarity) throws {
        guard similarity.space.domain == .faceIdentity,
              similarity.space.artifactManifest.hex == binding.fields["artifactManifestSHA256"]
        else { throw PortraitFailure.bindingMismatch }
        self.binding = binding; self.similarity = similarity
    }
}

/// Serialized lifecycle; the caller controls execution and cancellation callbacks run unlocked.
public final class ComparisonOperationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var outstanding: ComparisonRequest?
    private var usedOperations: Set<String> = []

    public init() {}

    public func begin(_ request: ComparisonRequest) throws {
        try lock.withLock {
            guard outstanding == nil else { throw PortraitFailure.operationUnavailable }
            guard let operationID = request.binding.fields["operationID"], !usedOperations.contains(operationID)
            else { throw PortraitFailure.operationReused }
            usedOperations.insert(operationID)
            outstanding = request
        }
    }

    /// Invalidate before invoking caller cancellation, including reentrant callbacks.
    public func cancel(operationID: String, onCancel: () throws -> Void) throws {
        try lock.withLock {
            guard outstanding?.binding.fields["operationID"] == operationID
            else { throw PortraitFailure.operationUnavailable }
            outstanding = nil
        }
        try onCancel()
    }

    /// Consumes exactly one valid completion; wrong bindings leave the active request intact.
    public func complete(binding: PortraitBinding) throws -> ComparisonRequest {
        try lock.withLock {
            guard let request = outstanding else { throw PortraitFailure.operationUnavailable }
            try request.binding.requireMatches(binding)
            outstanding = nil
            return request
        }
    }
}
