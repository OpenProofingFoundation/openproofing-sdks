import DocumentSDK
import DocumentCaptureApple
import Foundation

/// The native SDK's facts retained without recomputing acquisition or clock correlation.
/// A signature binds these local observations; it does not establish sensor authenticity.
struct DocumentFlowCaptureMetadata: Codable, Sendable {
    struct Frame: Codable, Sendable {
        let metadata: DocumentTemporalFrameMetadata
        let payload: Data
    }
    struct Temporal: Codable, Sendable {
        let manifest: DocumentTemporalManifest
        let frames: [Frame]
    }

    let schemaVersion: Int
    let captureID: UUID
    let sessionID: CaptureSessionID
    let side: DocumentSide
    let origin: MediaOrigin
    let requestedAt: Date
    let captureTimestamp: DocumentCaptureClockTimestamp
    let processedAt: Date
    let fidelity: PhotoFidelityMetadata
    let admission: DocumentCaptureAdmissionSnapshot?
    let platformMetadata: CapturedPhotoPlatformMetadata?
    let location: CaptureLocationRecord?
    let temporalEvidence: Temporal?
    let motionEvidence: DocumentMotionEvidence?
    let admittedLivePDF417Candidate: String?

    init(_ photo: CapturedDocumentPhoto, captureID: UUID, admittedLivePDF417Candidate: String? = nil) {
        schemaVersion = 1; self.captureID = captureID
        sessionID = photo.sessionID; side = photo.side; origin = photo.origin
        requestedAt = photo.requestedAt; captureTimestamp = photo.captureTimestamp
        processedAt = photo.processedAt; fidelity = photo.fidelity; admission = photo.admission
        platformMetadata = photo.platformMetadata; location = photo.location
        temporalEvidence = photo.temporalEvidence.map { evidence in
            Temporal(manifest: evidence.manifest, frames: evidence.frames.map { Frame(metadata: $0.metadata, payload: $0.payload) })
        }
        motionEvidence = photo.motionEvidence
        self.admittedLivePDF417Candidate = admittedLivePDF417Candidate
    }

    func requireBinding(to source: DocumentFlowSource) throws {
        guard schemaVersion == 1, captureID == source.captureID, side == source.side,
            origin == .liveSensor, processedAt == source.capturedAt,
            fidelity.sha256 == source.sha256, fidelity.pixelWidth == source.pixelWidth,
            fidelity.pixelHeight == source.pixelHeight, fidelity.fileByteCount == source.data.count
        else { throw DocumentFlowFailure.sourceBinding }
        if let admission {
            guard admission.sessionID == sessionID, admission.side == side,
                admission.userRequestedAt == requestedAt else { throw DocumentFlowFailure.sourceBinding }
        }
        if let admittedLivePDF417Candidate {
            guard side == .back, !admittedLivePDF417Candidate.isEmpty,
                admission?.qualityGate == .livePDF417AutoCapture else { throw DocumentFlowFailure.sourceBinding }
        } else if admission?.qualityGate == .livePDF417AutoCapture {
            throw DocumentFlowFailure.sourceBinding
        }
        if let temporalEvidence {
            let binding = temporalEvidence.manifest.binding
            guard binding.sessionID == sessionID.rawValue.uuidString, binding.side == side.rawValue,
                binding.stillSHA256 == source.sha256, binding.stillTimestamp == captureTimestamp,
                binding.attemptID == admission?.attemptID.uuidString else { throw DocumentFlowFailure.sourceBinding }
        }
        if let motionEvidence {
            try motionEvidence.requireValid()
            let binding = motionEvidence.binding
            guard binding.sessionID == sessionID.rawValue.uuidString, binding.side == side.rawValue,
                binding.stillSHA256 == source.sha256, binding.stillTimestamp == captureTimestamp,
                binding.attemptID == admission?.attemptID.uuidString else { throw DocumentFlowFailure.sourceBinding }
        }
    }
}
