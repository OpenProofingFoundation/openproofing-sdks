import Foundation

/// The database, not a preceding callback, supplies every engine's input.
struct FaceWorkflowPipeline: Sendable {
    let scheduler = FaceInferenceScheduler.shared
    let persistence: FaceWorkflowPersistence
    let compare: @Sendable (FaceComparisonInput) async throws -> FaceComparisonCompletion

    func runAura(_ requested: FaceComparisonInput, preparedCompare: (@Sendable (FaceComparisonInput) async throws -> FaceComparisonCompletion)? = nil) async throws -> FaceComparisonCompletion {
        let capture = try await storedCapture(requested)
        if let previous = try await persistence.loadStage(requested.operationID, .aura), let result = previous.aura {
            return result
        }
        let started = ContinuousClock.now
        let outcome: Result<FaceComparisonCompletion, Error>
        do { outcome = .success(try await scheduler.run { try await (preparedCompare ?? compare)(capture.input) }) }
        catch { outcome = .failure(error) }
        let stage: SavedFaceStage
        switch outcome {
        case .success(let value):
            stage = SavedFaceStage(operationID: requested.operationID, engine: .aura,
                durationMilliseconds: Self.elapsed(started), aura: value)
        case .failure(let error):
            stage = SavedFaceStage(operationID: requested.operationID, engine: .aura,
                durationMilliseconds: Self.elapsed(started),
                errorCode: error is CancellationError ? "comparison.error.interrupted" : "comparison.error.engine")
        }
        try stage.validate(for: capture)
        // Cancellation withdraws publication; a settled engine outcome still crosses the durable boundary.
        // The original repository generation continues to fence deletion and replacement during this commit.
        try await Task.detached { [persistence] in
            try await persistence.saveStage(stage)
            guard let committed = try await persistence.loadStage(stage.operationID, .aura), committed.id == stage.id else {
                throw FaceWorkflowStorageFailure.conflict
            }
        }.value
        try Task.checkCancellation()
        return try outcome.get()
    }



    private func storedCapture(_ requested: FaceComparisonInput) async throws -> SavedFaceCapture {
        let capture = try await persistence.loadCapture(requested.operationID)
        try capture.validate()
        guard capture.input.reference == requested.reference, capture.input.selfie == requested.selfie,
              capture.input.referenceSHA256 == requested.referenceSHA256, capture.input.selfieSHA256 == requested.selfieSHA256,
              capture.input.captureContext == requested.captureContext, capture.input.selection == requested.selection, capture.input.workflowID == requested.workflowID,
              capture.input.captureEventID == requested.captureEventID, capture.input.passport?.id == requested.passport?.id else {
            throw FaceWorkflowStorageFailure.conflict
        }
        try Task.checkCancellation()
        return capture
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
