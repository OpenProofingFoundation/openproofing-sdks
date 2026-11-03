import Foundation

extension CaptureEvidenceStore {
  /// Publishes only a completed attempt. Payload and native artifacts occupy ONE immutable
  /// encrypted record, so a failed write cannot leave a latest-result pointer to partial evidence.
  /// Failed retries need no write; the previous completed revision remains discoverable.
  ///
  /// Cancellation is checked immediately before publication. Once publication succeeds, a later
  /// cancellation cannot roll it back: callers recover the committed revision after a lost reply.
  /// Ordinary `removeAll()` retains the working key; `CaptureCustodyRuntime.erase()` permanently
  /// revokes delayed publishers and removes records and key. No separate persistence registry exists.
  public func commitCompletedResult<Payload: Codable & Sendable>(
    workflowID: UUID, kind: String, payload: Payload, artifacts: [CaptureResultArtifact],
    recordedAt: Date, expectedRevision: UInt64?
  ) throws -> CaptureCompletedResult<Payload> {
    try withCompletedResultPublication {
      let previous = try latestCompletedEnvelopes(workflowID: workflowID, kind: kind).first
      guard previous?.descriptor.revision == expectedRevision else {
        throw CaptureCompletedResultError.staleRevision
      }
      guard expectedRevision != UInt64.max else {
        throw CaptureCompletedResultError.invalidResult
      }
      let retained = artifacts.map { artifact in
        CaptureCompletedResultEnvelope.Artifact(
          reference: CaptureResultArtifactReference(
            id: artifact.id, role: artifact.role, mediaType: artifact.mediaType,
            sha256: CaptureEvidenceEnvelope.hash(artifact.data), byteCount: artifact.data.count),
          data: artifact.data)
      }
      let descriptor = CaptureCompletedResultDescriptor(
        id: UUID(), workflowID: workflowID, kind: kind, revision: (expectedRevision ?? 0) + 1,
        previousResultID: previous?.descriptor.id, recordedAt: recordedAt,
        artifacts: retained.map(\.reference))
      let envelope = CaptureCompletedResultEnvelope(
        descriptor: descriptor, payload: try JSONEncoder().encode(payload), artifacts: retained)
      try envelope.validate()
      let manifest = CaptureCompletedResultEnvelope.Manifest(
        schemaVersion: 1, recordKind: CaptureCompletedResultEnvelope.recordKind,
        captureID: workflowID, descriptor: descriptor)
      let encoded = try JSONEncoder().encode(envelope)
      let metadata = try JSONEncoder().encode(manifest)
      try Task.checkCancellation()
      try store(id: descriptor.id, original: encoded, manifest: metadata)
      return CaptureCompletedResult(descriptor: descriptor, payload: payload)
    }
  }

  /// Missing is nil; unreadable evidence, a broken revision chain, or incompatible payload throws.
  public func completedResult<Payload: Decodable & Sendable>(
    workflowID: UUID, kind: String, as type: Payload.Type
  ) throws -> CaptureCompletedResult<Payload>? {
    guard let value = try latestCompletedEnvelopes(workflowID: workflowID, kind: kind).first else {
      return nil
    }
    return CaptureCompletedResult(
      descriptor: value.descriptor, payload: try JSONDecoder().decode(type, from: value.payload))
  }

  /// Reads one immutable publication, including an older revision. Its envelope and artifact
  /// digests are verified; callers must check the workflow, kind and payload they expect.
  public func completedResult<Payload: Decodable & Sendable>(
    id: UUID, as type: Payload.Type
  ) throws -> CaptureCompletedResult<Payload> {
    let value = try completedEnvelope(id: id)
    return CaptureCompletedResult(
      descriptor: value.descriptor, payload: try JSONDecoder().decode(type, from: value.payload))
  }

  /// Discovery across restart does not require a host-maintained plaintext identity index.
  public func completedResults(kind: String? = nil) throws -> [CaptureCompletedResultDescriptor] {
    try latestCompletedEnvelopes(workflowID: nil, kind: kind).map(\.descriptor)
  }

  /// Deletes every revision of this workflow's completed results of the given kinds, with their
  /// native artifacts, under the publication lock. Revisions go newest first, so an interrupted
  /// erase leaves a valid shorter chain that a repeated call finishes. Returns the count deleted.
  /// Other workflows, and other kinds in this workflow, are untouched.
  public func removeCompletedResults(workflowID: UUID, kinds: Set<String>) throws -> Int {
    try withCompletedResultPublication {
      let ids = try matchingRecordIDs(
        captureID: workflowID, recordKind: CaptureCompletedResultEnvelope.recordKind)
      var selected: [(id: UUID, revision: UInt64)] = []
      for id in ids {
        let manifest = try JSONDecoder().decode(
          CaptureCompletedResultEnvelope.Manifest.self, from: metadata(id: id))
        guard manifest.schemaVersion == 1,
          manifest.recordKind == CaptureCompletedResultEnvelope.recordKind,
          manifest.captureID == workflowID, manifest.descriptor.workflowID == workflowID,
          manifest.descriptor.id == id
        else { throw CaptureCompletedResultError.invalidResult }
        if kinds.contains(manifest.descriptor.kind) {
          selected.append((id, manifest.descriptor.revision))
        }
      }
      for record in selected.sorted(by: { $0.revision > $1.revision }) {
        try removeRecord(id: record.id)
      }
      return selected.count
    }
  }

  public func completedResultArtifact(
    resultID: UUID, artifactID: UUID, expectedSHA256: String
  ) throws -> Data {
    let value = try completedEnvelope(id: resultID)
    guard let artifact = value.artifacts.first(where: { $0.reference.id == artifactID }),
      artifact.reference.sha256 == expectedSHA256
    else { throw CaptureCompletedResultError.invalidArtifact }
    return artifact.data
  }

  private func latestCompletedEnvelopes(workflowID: UUID?, kind: String?) throws
    -> [CaptureCompletedResultEnvelope]
  {
    let ids = try matchingRecordIDs(
      captureID: workflowID, recordKind: CaptureCompletedResultEnvelope.recordKind)
    let records = try ids.map { try completedEnvelope(id: $0) }.filter {
      kind == nil || $0.descriptor.kind == kind
    }
    let groups = Dictionary(grouping: records) {
      $0.descriptor.workflowID.uuidString + "/" + $0.descriptor.kind
    }
    return try groups.values.map { records in
      let ordered = records.sorted { $0.descriptor.revision < $1.descriptor.revision }
      var previous: CaptureCompletedResultEnvelope?
      for current in ordered {
        guard current.descriptor.revision == (previous?.descriptor.revision ?? 0) + 1,
          current.descriptor.previousResultID == previous?.descriptor.id
        else { throw CaptureCompletedResultError.invalidResult }
        previous = current
      }
      guard let previous else { throw CaptureCompletedResultError.invalidResult }
      return previous
    }.sorted { $0.descriptor.id.uuidString < $1.descriptor.id.uuidString }
  }

  private func completedEnvelope(id: UUID) throws -> CaptureCompletedResultEnvelope {
    let record = try read(id: id)
    let manifest = try JSONDecoder().decode(
      CaptureCompletedResultEnvelope.Manifest.self, from: record.manifest)
    let envelope = try JSONDecoder().decode(
      CaptureCompletedResultEnvelope.self, from: record.original)
    guard manifest.schemaVersion == 1,
      manifest.recordKind == CaptureCompletedResultEnvelope.recordKind,
      manifest.captureID == envelope.descriptor.workflowID,
      manifest.descriptor == envelope.descriptor, envelope.descriptor.id == id
    else { throw CaptureCompletedResultError.invalidResult }
    try envelope.validate()
    return envelope
  }
}
