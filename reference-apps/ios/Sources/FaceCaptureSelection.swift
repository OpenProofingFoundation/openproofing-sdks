import BiometricCapture
import BiometricInference
import BiometricQuality
import Foundation

/// Public observations and original per-frame receipts; pixels remain in the selected capture only.
struct FaceCaptureSelectionRecord: Codable, Equatable, Sendable {
    struct Quality: Codable, Equatable, Sendable {
        struct Component: Codable, Equatable, Sendable {
            let measureID: Int32
            let code: Int32
            let native: Double?
            let mapped: Double?
        }
        let sourceSHA256: String
        let rasterSHA256: String
        let artifactManifestSHA256: String
        let returnCode: Int32
        let faceCount: Int32
        let components: [Component]
        var uqs: Component? { components.first { $0.measureID == 0x41 } }
    }
    struct Preparation: Codable, Equatable, Sendable {
        let sourceSHA256: String
        let alignedSHA256: String
        let artifactManifestSHA256: String
        let alignmentRoute: String
    }
    struct Candidate: Codable, Equatable, Sendable {
        let index: Int
        let capture: FaceCaptureContext
        let quality: Quality?
        let preparation: Preparation?
        let failureCode: String?
        var exclusions: UInt32
    }
    let version: Int
    let policyID: String
    let policySHA256: String
    let qualityArtifactSHA256: String
    let matcherArtifactSHA256: String
    let selectedCaptureID: UUID
    let selectedSHA256: String
    let selectedAlignedSHA256: String
    let candidates: [Candidate]

    func validate(selected: FaceCaptureContext, imageSHA256: String) throws {
        guard version == 1, policyID == FaceCaptureSelectionProcessor.policyID,
              !candidates.isEmpty, candidates.count <= 12,
              Set(candidates.map { $0.capture.captureID }).count == candidates.count,
              candidates.map(\.index) == Array(candidates.indices),
              selectedCaptureID == selected.captureID, selectedSHA256 == selected.selfieSHA256,
              selectedSHA256 == imageSHA256,
              let winner = candidates.first(where: { $0.capture.captureID == selectedCaptureID }),
              winner.capture == selected, winner.exclusions == 0,
              winner.preparation?.alignedSHA256 == selectedAlignedSHA256 else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
        guard policySHA256 == FaceCaptureSelectionProcessor.policySHA256,
              qualityArtifactSHA256 == OFIQFaceQuality.artifactManifestSHA256,
              matcherArtifactSHA256 == FaceCaptureSelectionProcessor.matcherManifest,
              [policySHA256, qualityArtifactSHA256, matcherArtifactSHA256, selectedSHA256, selectedAlignedSHA256].allSatisfy(Self.isDigest) else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
        var descriptors: [FaceFrameSelection.Candidate] = []
        for candidate in candidates {
            _ = try FaceComparisonHost.captureMeasurements(candidate.capture, selfieSHA256: candidate.capture.selfieSHA256)
            guard candidate.capture.receipt.admissionValid,
                  candidate.failureCode.map({ Self.failureCodes.contains($0) }) ?? true,
                  candidate.preparation == nil || candidate.failureCode == nil,
                  candidate.quality.map({ $0.sourceSHA256 == candidate.capture.selfieSHA256 && $0.artifactManifestSHA256 == qualityArtifactSHA256 }) ?? true,
                  candidate.preparation.map({ $0.sourceSHA256 == candidate.capture.selfieSHA256 && $0.artifactManifestSHA256 == matcherArtifactSHA256
                      && $0.alignmentRoute == "apple-vision-revision3-five-point-cpp-bilinear-v1" }) ?? true else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
            let q = candidate.quality, p = candidate.preparation, score = q?.uqs
            guard Self.isDigest(candidate.capture.selfieSHA256),
                  q.map({ Self.isDigest($0.rasterSHA256) && (0...11).contains($0.returnCode) && $0.faceCount >= 0 && $0.components.count == 28
                      && Set($0.components.map(\.measureID)) == Set(Int32(0x41)...Int32(0x5c)) && $0.components.allSatisfy { component in
                      (0...2).contains(component.code) && (component.native.map(\.isFinite) ?? true) && (component.mapped.map(\.isFinite) ?? true)
                  } }) ?? true,
                  p.map({ Self.isDigest($0.alignedSHA256) }) ?? true else { throw FaceWorkflowStorageFailure.invalidRecord }
            descriptors.append(.init(source: .init(identifier: candidate.capture.captureID.uuidString, originalFrameIndex: UInt32(candidate.index), sha256: candidate.capture.selfieSHA256),
                quality: .init(sourceSHA256: q?.sourceSHA256, returnCode: q?.returnCode ?? -1, faceCount: q?.faceCount ?? -1,
                    score: .init(code: score?.code ?? -1, native: score?.native ?? .nan, mapped: score?.mapped ?? .nan)),
                matcher: .init(sourceSHA256: p?.sourceSHA256, status: p == nil ? .failed : .passed, alignedSHA256: p?.alignedSHA256)))
        }
        let replay = try FaceFrameSelection.select(descriptors, configuration: .init(policy: .highestNativeUQS, identities: .init(
            policy: .init(identifier: policyID, sha256: policySHA256), qualityArtifact: .init(identifier: "ofiq-1.0.3-mobile-v1", sha256: qualityArtifactSHA256),
            matcherArtifact: .init(identifier: "sdk-vision3-cpp-preflight-v1", sha256: matcherArtifactSHA256))))
        guard case let .selected(winner) = replay.outcome, winner.source.identifier == selectedCaptureID.uuidString,
              winner.alignedSHA256 == selectedAlignedSHA256,
              zip(replay.candidates, candidates).allSatisfy({ $0.exclusions.rawValue == $1.exclusions }) else {
            throw FaceWorkflowStorageFailure.invalidRecord
        }
    }
    private static let failureCodes: Set<String> = ["assessment_failed", "quality_ineligible", "preparation_failed",
        "invalid_image", "resource_limit", "source_mismatch", "face_missing", "multiple_faces", "landmarks_unavailable",
        "model_unavailable", "alignment_failed", "inference_failed"]
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct FaceCaptureSelectionRefusal: Error, Sendable {
    let reason: FaceCaptureSelectionFailure
    let policyID: String
    let policySHA256: String
    let qualityArtifactSHA256: String
    let matcherArtifactSHA256: String
    let candidates: [FaceCaptureSelectionRecord.Candidate]
}

struct FaceCaptureSelectionProgress: Sendable, Equatable {
    enum Stage: String, Sendable { case quality, preparation, selection }
    let stage: Stage
    let completed: Int
    let total: Int
}

enum FaceCaptureSelectionFailure: String, Error, Sendable {
    case resources, source, qualityUnavailable, qualityFailed, modelUnavailable, noSelection
    var messageKey: String { "capture.selection.failure.\(rawValue)" }
}

struct SelectedSelfie: Sendable {
    let capture: CapturedSelfie
    let snapshot: SelfiePixelSnapshot
    let record: FaceCaptureSelectionRecord
    let prepared: FaceImagePreflightObservation
}
