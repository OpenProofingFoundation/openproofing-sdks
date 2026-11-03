import AuraFaceNative

/// Deterministic selection over host-observed, source-bound quality and matcher preparation.
/// This mechanism does not establish identity, liveness, quality calibration, or trusted provenance.
public enum FaceFrameSelection {
    public static let maximumCandidates = Int(FACE_SELECTION_MAX_CANDIDATES)

    public enum Policy: Int32, Sendable { case firstEligible = 0, highestNativeUQS = 1 }
    public enum MatcherStatus: Int32, Sendable { case notAssessed = 0, passed = 1, failed = 2 }
    public struct Identity: Sendable, Equatable {
        public let identifier: String
        public let sha256: String
        public init(identifier: String, sha256: String) { self.identifier = identifier; self.sha256 = sha256 }
    }
    public struct Identities: Sendable, Equatable {
        public let policy: Identity
        public let qualityArtifact: Identity
        public let matcherArtifact: Identity
        public init(policy: Identity, qualityArtifact: Identity, matcherArtifact: Identity) {
            self.policy = policy; self.qualityArtifact = qualityArtifact; self.matcherArtifact = matcherArtifact
        }
    }
    public struct Configuration: Sendable, Equatable {
        public let policy: Policy
        public let identities: Identities
        public init(policy: Policy, identities: Identities) { self.policy = policy; self.identities = identities }
    }
    public struct Source: Sendable, Equatable {
        public let identifier: String
        public let originalFrameIndex: UInt32
        public let sha256: String
        public init(identifier: String, originalFrameIndex: UInt32, sha256: String) {
            self.identifier = identifier; self.originalFrameIndex = originalFrameIndex; self.sha256 = sha256
        }
    }
    public struct Score: Sendable, Equatable {
        public let code: Int32
        public let native: Double
        public let mapped: Double
        public init(code: Int32, native: Double, mapped: Double) {
            self.code = code; self.native = native; self.mapped = mapped
        }
    }
    public struct Quality: Sendable, Equatable {
        public let sourceSHA256: String?
        public let returnCode: Int32
        public let faceCount: Int32
        public let score: Score
        public init(sourceSHA256: String?, returnCode: Int32, faceCount: Int32, score: Score) {
            self.sourceSHA256 = sourceSHA256; self.returnCode = returnCode; self.faceCount = faceCount; self.score = score
        }
    }
    public struct Matcher: Sendable, Equatable {
        public let sourceSHA256: String?
        public let status: MatcherStatus
        public let alignedSHA256: String?
        public init(sourceSHA256: String?, status: MatcherStatus, alignedSHA256: String? = nil) {
            self.sourceSHA256 = sourceSHA256; self.status = status; self.alignedSHA256 = alignedSHA256
        }
    }
    public struct Candidate: Sendable, Equatable {
        public let source: Source
        public let quality: Quality
        public let matcher: Matcher
        public init(source: Source, quality: Quality, matcher: Matcher) {
            self.source = source; self.quality = quality; self.matcher = matcher
        }
    }
    public struct Exclusions: OptionSet, Sendable, Equatable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let qualityFailed = Self(rawValue: FACE_SELECTION_QUALITY_FAILED)
        public static let faceCount = Self(rawValue: FACE_SELECTION_FACE_COUNT)
        public static let uqsFailed = Self(rawValue: FACE_SELECTION_UQS_FAILED)
        public static let invalidUQS = Self(rawValue: FACE_SELECTION_INVALID_UQS)
        public static let qualitySourceMismatch = Self(rawValue: FACE_SELECTION_QUALITY_SOURCE_MISMATCH)
        public static let matcherPreparationUnavailable = Self(rawValue: FACE_SELECTION_MATCHER_NOT_PASSED)
        public static let matcherSourceMismatch = Self(rawValue: FACE_SELECTION_MATCHER_SOURCE_MISMATCH)
        public static let alignedUnavailable = Self(rawValue: FACE_SELECTION_ALIGNED_UNAVAILABLE)
    }
    public struct CandidateResult: Sendable, Equatable {
        public let source: Source
        public let exclusions: Exclusions
    }
    public struct Selection: Sendable, Equatable {
        public let source: Source
        public let alignedSHA256: String
        public let inputOffset: Int
    }
    public enum Outcome: Sendable, Equatable { case selected(Selection), noSelection }
    public struct Report: Sendable, Equatable {
        public let configuration: Configuration
        public let candidates: [CandidateResult]
        public let outcome: Outcome
    }
    public enum Failure: Error, Sendable {
        case invalidConfiguration, invalidCandidate, duplicateIdentifier, duplicateIndex, tooManyCandidates, invalidBuffers
    }

    public static func select(_ candidates: [Candidate], configuration: Configuration) throws -> Report {
        guard candidates.count <= maximumCandidates else { throw Failure.tooManyCandidates }
        var nativeConfiguration = try encode(configuration)
        let nativeCandidates = try candidates.map(encode)
        var exclusions = [UInt32](repeating: 0, count: candidates.count)
        var result = FaceSelectionResult()
        let status = nativeCandidates.withUnsafeBufferPointer { inputs in
            exclusions.withUnsafeMutableBufferPointer { outputs in
                face_select_frame(&nativeConfiguration, inputs.baseAddress, inputs.count,
                                  outputs.baseAddress, outputs.count, &result)
            }
        }
        try check(status)
        let rows = zip(candidates, exclusions).map { CandidateResult(source: $0.0.source, exclusions: .init(rawValue: $0.1)) }
        let outcome: Outcome
        if result.has_selection == 0 {
            outcome = .noSelection
        } else {
            let offset = Int(result.selected_input_offset)
            guard candidates.indices.contains(offset), let aligned = candidates[offset].matcher.alignedSHA256 else {
                throw Failure.invalidBuffers
            }
            outcome = .selected(Selection(source: candidates[offset].source, alignedSHA256: aligned, inputOffset: offset))
        }
        return Report(configuration: configuration, candidates: rows, outcome: outcome)
    }

    private static func encode(_ value: Configuration) throws -> FaceSelectionConfiguration {
        var output = FaceSelectionConfiguration()
        output.policy = value.policy.rawValue
        output.policy_identity = try encode(value.identities.policy)
        output.quality_artifact = try encode(value.identities.qualityArtifact)
        output.matcher_artifact = try encode(value.identities.matcherArtifact)
        return output
    }
    private static func encode(_ value: Identity) throws -> FaceSelectionIdentity {
        var output = FaceSelectionIdentity()
        try copy(value.identifier, into: &output.identifier, failure: .invalidConfiguration)
        try copy(value.sha256, into: &output.sha256, failure: .invalidConfiguration)
        return output
    }
    private static func encode(_ value: Candidate) throws -> FaceSelectionCandidate {
        var output = FaceSelectionCandidate()
        try copy(value.source.identifier, into: &output.candidate_id, failure: .invalidCandidate)
        output.original_frame_index = value.source.originalFrameIndex
        try copy(value.source.sha256, into: &output.source_sha256, failure: .invalidCandidate)
        try copy(value.quality.sourceSHA256 ?? "", into: &output.quality_source_sha256, failure: .invalidCandidate)
        try copy(value.matcher.sourceSHA256 ?? "", into: &output.matcher_source_sha256, failure: .invalidCandidate)
        try copy(value.matcher.alignedSHA256 ?? "", into: &output.aligned_sha256, failure: .invalidCandidate)
        output.quality_return_code = value.quality.returnCode
        output.face_count = value.quality.faceCount
        output.uqs_return_code = value.quality.score.code
        output.uqs_native = value.quality.score.native
        output.uqs_mapped = value.quality.score.mapped
        output.matcher_status = value.matcher.status.rawValue
        return output
    }
    private static func copy<T>(_ value: String, into output: inout T, failure: Failure) throws {
        let bytes = Array(value.utf8)
        guard !bytes.contains(0), bytes.count < MemoryLayout<T>.size else { throw failure }
        withUnsafeMutableBytes(of: &output) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: bytes)
        }
    }
    private static func check(_ status: FaceSelectionStatus) throws {
        switch status {
        case FACE_SELECTION_SUCCESS: return
        case FACE_SELECTION_INVALID_CONFIGURATION: throw Failure.invalidConfiguration
        case FACE_SELECTION_INVALID_CANDIDATE: throw Failure.invalidCandidate
        case FACE_SELECTION_DUPLICATE_IDENTIFIER: throw Failure.duplicateIdentifier
        case FACE_SELECTION_DUPLICATE_INDEX: throw Failure.duplicateIndex
        case FACE_SELECTION_TOO_MANY_CANDIDATES: throw Failure.tooManyCandidates
        default: throw Failure.invalidBuffers
        }
    }
}
