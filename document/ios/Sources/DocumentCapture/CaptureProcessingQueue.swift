#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  /// One processing worker; acquisition never awaits OCR or licensed extraction.
  @MainActor
  public final class CaptureProcessingQueue {
    public struct Job {
      public let captureID: UUID
      public let workflowID: UUID
      public let profile: CaptureRecords.Profile
      public let publicationEpoch: UUID
      public let store: CaptureEvidenceStore
      public var progress: (CaptureDocumentRecovery.Stage) -> Void = { _ in }
      public init(
        captureID: UUID, workflowID: UUID, profile: CaptureRecords.Profile,
        publicationEpoch: UUID, store: CaptureEvidenceStore,
        progress: @escaping (CaptureDocumentRecovery.Stage) -> Void = { _ in }
      ) {
        self.captureID = captureID
        self.workflowID = workflowID
        self.profile = profile
        self.publicationEpoch = publicationEpoch
        self.store = store
        self.progress = progress
      }
    }
    public typealias Worker = @MainActor (Job) async throws -> DocumentCaptureExpectationAssessment
    public typealias Completion =
      @MainActor (Job, Result<DocumentCaptureExpectationAssessment, Error>) async -> Void
    private let worker: Worker
    private var task: Task<Void, Never>?
    private var cancelling = false
    private var pending: [Job] = []
    public private(set) var activeID: UUID?
    public var completion: Completion = { _, _ in }
    public var changed: () -> Void = {}
    public var superseded: (UUID) -> Void = { _ in }

    public init(
      worker: @escaping Worker = { job in
        try await CaptureDocumentRecovery.process(
          captureID: job.captureID, store: job.store,
          onStage: { job.progress($0) })
      }
    ) { self.worker = worker }

    /// Preserved work needs discovery; cancelled old work cannot request archive scans.
    public var captureIDs: Set<UUID> {
      var ids = Set(pending.map(\.captureID))
      if !cancelling, let activeID { ids.insert(activeID) }
      return ids
    }

    public func contains(_ id: UUID) -> Bool {
      (activeID == id && !cancelling) || pending.contains { $0.captureID == id }
    }

    public func enqueue(_ job: Job) {
      guard !contains(job.captureID) else { return }
      let replaced = pending.filter { $0.profile == job.profile }
      pending.removeAll { $0.profile == job.profile }
      for previous in replaced { superseded(previous.captureID) }
      if pending.count == 2 { superseded(pending.removeFirst().captureID) }
      pending.append(job)
      changed()
      launchIfNeeded()
    }

    public func cancel() {
      cancelling = true
      for job in pending { superseded(job.captureID) }
      pending.removeAll()
      task?.cancel()
      changed()
    }

    public func waitUntilIdle() async { await task?.value }

    private func launchIfNeeded() {
      guard task == nil, !pending.isEmpty else { return }
      cancelling = false
      task = Task { [self] in
        while !pending.isEmpty, !Task.isCancelled {
          let job = pending.removeFirst()
          activeID = job.captureID
          changed()
          let result: Result<DocumentCaptureExpectationAssessment, Error>
          do { result = .success(try await worker(job)) } catch { result = .failure(error) }
          if !Task.isCancelled { await completion(job, result) }
          activeID = nil
          changed()
        }
        task = nil
        launchIfNeeded()
      }
    }
  }
#endif
