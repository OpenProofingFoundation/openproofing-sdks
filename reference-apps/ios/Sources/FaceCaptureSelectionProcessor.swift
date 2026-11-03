import BiometricCapture
import BiometricInference
import BiometricQuality
import Foundation

/// One scheduler lease spans quality-kernel settlement, closure and matcher preparation.
/// Cosine/embedding values never enter the selector; only the selected owner escapes.
enum FaceCaptureSelectionProcessor {
    static let policyID = "native-uqs-matcher-compatible-v1"
    static let policySHA256 = "d86a3a8ea2fc81009782e879800586b90d5c1e4fb290b872d57e81e6e25db9a4"
    static let matcherManifest = "9db36f239a89adfa6794f616f7face61f5ba1b0ca0c7f26b93a6204001856347"
    typealias Progress = @MainActor @Sendable (FaceCaptureSelectionProgress) -> Void

    static func run(_ captures: [CapturedSelfie], qualityDirectory: URL?, modelURL: URL?,
                    qualitySession: (any FaceCaptureQualitySession)? = nil, progress: @escaping Progress) async throws -> SelectedSelfie {
        try await FaceInferenceScheduler.shared.run {
            try await select(captures, qualityDirectory: qualityDirectory, modelURL: modelURL, qualitySession: qualitySession, progress: progress)
        }
    }

    private static func select(_ captures: [CapturedSelfie], qualityDirectory: URL?, modelURL: URL?,
                               qualitySession: (any FaceCaptureQualitySession)?, progress: @escaping Progress) async throws -> SelectedSelfie {
        guard !captures.isEmpty, captures.count <= 12,
              captures.reduce(0, { $0 + $1.encodedPNG.count }) <= 64 * 1024 * 1024 else { throw FaceCaptureSelectionFailure.resources }
        guard Set(captures.map(\.id)).count == captures.count,
              captures.allSatisfy({ $0.admissionReceipt.admissionValid }) else { throw FaceCaptureSelectionFailure.source }
        do {
            for capture in captures { _ = try FaceComparisonHost.captureMeasurements(FaceCaptureContext(capture: capture), selfieSHA256: capture.sha256) }
        } catch { throw FaceCaptureSelectionFailure.source }
        guard let qualityDirectory else { throw FaceCaptureSelectionFailure.qualityUnavailable }
        guard let modelURL else { throw FaceCaptureSelectionFailure.modelUnavailable }
        try Task.checkCancellation()
        let quality: any FaceCaptureQualitySession
        if let qualitySession { quality = qualitySession }
        else {
            do { quality = try NativeFaceCaptureQualitySession(directory: qualityDirectory) }
            catch { throw FaceCaptureSelectionFailure.qualityUnavailable }
        }
        var records: [FaceCaptureSelectionRecord.Candidate] = []
        var totalPixels = 0
        do {
            for (index, capture) in captures.enumerated() {
                try Task.checkCancellation()
                let snapshot = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
                totalPixels += snapshot.pixels.width * snapshot.pixels.height
                guard totalPixels <= 32_000_000 else { throw FaceCaptureSelectionFailure.resources }
                let observation: FaceCaptureSelectionRecord.Quality?
                let failure: String?
                do {
                    let result = try await quality.assess(snapshot)
                    guard result.sourceSHA256 == capture.sha256, result.rasterSHA256 == snapshot.pixels.sha256 else { throw FaceCaptureSelectionFailure.source }
                    observation = result; failure = nil
                } catch FaceQualityFailure.assessmentFailed {
                    observation = nil; failure = FaceQualityFailure.assessmentFailed.rawValue
                }
                records.append(.init(index: index, capture: FaceCaptureContext(capture: capture), quality: observation,
                    preparation: nil, failureCode: failure, exclusions: 0))
                await progress(.init(stage: .quality, completed: index + 1, total: captures.count))
            }
        } catch {
            await quality.close()
            throw error
        }
        // No OFIQ native session survives into AuraFace model loading/comparison.
        await quality.close()
        try Task.checkCancellation()
        let qualityManifest = OFIQFaceQuality.artifactManifestSHA256
        guard records.allSatisfy({ $0.quality.map { $0.artifactManifestSHA256 == qualityManifest } ?? true }) else { throw FaceCaptureSelectionFailure.source }
        // The initializer stores the URL; preflight never loads the embedding model.
        let engine = AuraFaceComparison(modelURL: modelURL)
        var owners: [FaceImagePreflightObservation?] = []
        var descriptors: [FaceFrameSelection.Candidate] = []
        for (index, capture) in captures.enumerated() {
            try Task.checkCancellation()
            let quality = records[index].quality
            let score = quality?.uqs
            var owner: FaceImagePreflightObservation?
            var failure = records[index].failureCode
            if quality?.returnCode == 0, quality?.faceCount == 1, score?.code == 0,
               let native = score?.native, native.isFinite, let mapped = score?.mapped, mapped.isFinite, (0...100).contains(mapped) {
                do { owner = try await engine.preflight(image: capture.encodedPNG, sourceSHA256: capture.sha256) }
                catch let reason as FaceInferenceFailure { failure = reason.rawValue }
                catch is CancellationError { throw CancellationError() }
                catch { failure = "preparation_failed" }
            } else if failure == nil { failure = "quality_ineligible" }
            owners.append(owner)
            let prepared = owner.map { FaceCaptureSelectionRecord.Preparation(sourceSHA256: $0.sourceSHA256,
                alignedSHA256: $0.alignedSHA256, artifactManifestSHA256: $0.artifactManifestSHA256, alignmentRoute: $0.alignmentRoute) }
            records[index] = .init(index: index, capture: records[index].capture, quality: quality,
                preparation: prepared, failureCode: failure, exclusions: 0)
            descriptors.append(.init(source: .init(identifier: capture.id.uuidString, originalFrameIndex: UInt32(index), sha256: capture.sha256),
                quality: .init(sourceSHA256: quality?.sourceSHA256, returnCode: quality?.returnCode ?? -1, faceCount: quality?.faceCount ?? -1,
                    score: .init(code: score?.code ?? -1, native: score?.native ?? .nan, mapped: score?.mapped ?? .nan)),
                matcher: .init(sourceSHA256: owner?.sourceSHA256, status: owner == nil ? .failed : .passed, alignedSHA256: owner?.alignedSHA256)))
            await progress(.init(stage: .preparation, completed: index + 1, total: captures.count))
        }
        try Task.checkCancellation()
        await progress(.init(stage: .selection, completed: 0, total: captures.count))
        let policySHA = try FaceComparisonHost.sourceDigest(PolicyIdentity(schemaVersion: 1, policy: "uqs", matcherRequired: true, rank: "highest-native-uqs-earliest-index-tie"))
        guard policySHA == policySHA256 else { throw FaceCaptureSelectionFailure.source }
        let result = try FaceFrameSelection.select(descriptors, configuration: .init(policy: .highestNativeUQS, identities: .init(
            policy: .init(identifier: policyID, sha256: policySHA), qualityArtifact: .init(identifier: "ofiq-1.0.3-mobile-v1", sha256: qualityManifest),
            matcherArtifact: .init(identifier: "sdk-vision3-cpp-preflight-v1", sha256: matcherManifest))))
        for index in records.indices { records[index].exclusions = result.candidates[index].exclusions.rawValue }
        guard case let .selected(winner) = result.outcome, let prepared = owners[winner.inputOffset] else {
            throw FaceCaptureSelectionRefusal(reason: .noSelection, policyID: policyID, policySHA256: policySHA,
                qualityArtifactSHA256: qualityManifest, matcherArtifactSHA256: matcherManifest, candidates: records)
        }
        let capture = captures[winner.inputOffset]
        let record = FaceCaptureSelectionRecord(version: 1, policyID: policyID, policySHA256: policySHA,
            qualityArtifactSHA256: qualityManifest, matcherArtifactSHA256: matcherManifest,
            selectedCaptureID: capture.id, selectedSHA256: capture.sha256, selectedAlignedSHA256: winner.alignedSHA256, candidates: records)
        try record.validate(selected: FaceCaptureContext(capture: capture), imageSHA256: capture.sha256)
        let snapshot = try SelfiePixelBridge.decodeOrientedPNG(capture.encodedPNG, expectedSourceSHA256: capture.sha256)
        try Task.checkCancellation()
        return SelectedSelfie(capture: capture, snapshot: snapshot, record: record, prepared: prepared)
    }
    private struct PolicyIdentity: Encodable { let schemaVersion: Int; let policy: String; let matcherRequired: Bool; let rank: String }
}
