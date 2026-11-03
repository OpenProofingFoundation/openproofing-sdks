import AVFoundation
import DocumentSDK
import DocumentCaptureApple
import Foundation

/// Thin reference-app adapter. Front admission and camera controls belong to the public SDK.
@MainActor final class NativeDocumentFlowCamera: DocumentFlowCamera {
    let front = DocumentFrontCaptureController(now: Date.init, notifications: .default)
    var camera: DocumentCamera { backCamera ?? front.camera }
    var captured: ((CapturedDocumentPhoto) -> Void)?
    var stopping: (() -> Void)?
    var selectedCameraChanged: ((DocumentSide) -> Void)?
    private(set) var authorizationPending = false
    private var backCamera: DocumentCamera?
    private var frontWasUsed = false
    private var generation: UInt64 = 0
    private var livePDF417Observer: (@MainActor (String) -> Void)?

    func observeAutomaticCapture(_ receive: @escaping @MainActor (DocumentCaptureObservationIdentity) -> Void) {
        front.onAutomaticCapture = receive
    }

    func observeLivePDF417(_ receive: @escaping @MainActor (String) -> Void) {
        livePDF417Observer = receive
    }

    func start() async throws { try await start(side: .front) }

    func start(side: DocumentSide) async throws {
        generation &+= 1
        let token = generation
        authorizationPending = AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
        defer { authorizationPending = false }
        if let previous = backCamera {
            try await previous.stopAndWait()
            guard token == generation else { throw CancellationError() }
            backCamera = nil
        }
        if side == .front {
            selectedCameraChanged?(.front)
            guard token == generation else { throw CancellationError() }
            try Task.checkCancellation()
            frontWasUsed = true
            try await front.start()
        } else {
            if frontWasUsed {
                try await front.stop()
                guard token == generation else { throw CancellationError() }
                frontWasUsed = false
            }
            let selected = DocumentCamera(now: Date.init, notifications: .default,
                configuration: .init(livePDF417: true),
                diagnostics: .init(livePDF417: true, includesAdaptiveCapture: true,
                    includesLiveContentAnalysis: false, liveContentTarget: .licensePDF417))
            backCamera = selected
            selectedCameraChanged?(.back)
            guard token == generation else { throw CancellationError() }
            try Task.checkCancellation()
            try await selected.start()
            guard token == generation else { throw CancellationError() }
            try Task.checkCancellation()
            // The SDK handler captures its native camera epoch at registration.
            selected.setLivePDF417Handler { [weak self, weak selected] payload in
                guard let self, let selected, self.generation == token,
                    self.backCamera === selected else { return }
                self.livePDF417Observer?(payload)
            }
        }
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func invalidatePendingAuthorization() {
        if authorizationPending { camera.stop() }
    }

    func stop() async throws {
        generation &+= 1
        stopping?()
        defer { stopping?() }
        var retirementFailure: (any Error)?
        if let backCamera {
            do { try await backCamera.stopAndWait() }
            catch { retirementFailure = error }
        }
        if frontWasUsed {
            do {
                try await front.stop()
                frontWasUsed = false
            } catch {
                if retirementFailure == nil { retirementFailure = error }
            }
        }
        if let retirementFailure { throw retirementFailure }
    }

    func capture(side: DocumentSide) async throws -> DocumentFlowSource {
        try await capture(side: side, observationIdentity: nil)
    }

    func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?) async throws -> DocumentFlowSource {
        try await capture(side: side, observationIdentity: observationIdentity, livePDF417Candidate: nil)
    }

    func capture(side: DocumentSide, observationIdentity: DocumentCaptureObservationIdentity?,
                 livePDF417Candidate: String?) async throws -> DocumentFlowSource {
        let token = generation
        let photo: CapturedDocumentPhoto
        if side == .front {
            guard backCamera == nil, livePDF417Candidate == nil else { throw DocumentFlowFailure.capture }
            photo = try await front.capture(observationIdentity: observationIdentity)
        } else {
            guard observationIdentity == nil, let backCamera else { throw DocumentFlowFailure.capture }
            if let livePDF417Candidate {
                photo = try await backCamera.capture(request: .init(side: .back,
                    qualityGate: .livePDF417AutoCapture, livePDF417Candidate: livePDF417Candidate))
            } else {
                photo = try await backCamera.capture(side: side)
            }
        }
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
        captured?(photo)
        let captureID = UUID()
        let metadata = try JSONEncoder().encode(DocumentFlowCaptureMetadata(photo, captureID: captureID,
            admittedLivePDF417Candidate: livePDF417Candidate))
        return DocumentFlowSource(side: photo.side, data: photo.data, sha256: photo.fidelity.sha256,
            pixelWidth: photo.fidelity.pixelWidth, pixelHeight: photo.fidelity.pixelHeight,
            captureID: captureID, capturedAt: photo.processedAt, nativeMetadata: metadata)
    }
}
