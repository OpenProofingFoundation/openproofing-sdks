#if os(iOS)
  import Foundation
  import DocumentCaptureApple
  import CaptureEvidenceCustody

  /// Optional on older originals. The original publishes this graph only after every child readback.
  public struct CaptureTemporalEvidenceReference: Codable {
    public let schemaVersion: Int
    public let recordID: UUID
    public let sha256: String
    public let frameCount: Int
    public let motionSampleCount: Int
    public let status: String

    public init(
      schemaVersion: Int,
      recordID: UUID,
      sha256: String,
      frameCount: Int,
      motionSampleCount: Int,
      status: String
    ) {
      self.schemaVersion = schemaVersion
      self.recordID = recordID
      self.sha256 = sha256
      self.frameCount = frameCount
      self.motionSampleCount = motionSampleCount
      self.status = status
    }
  }

  @MainActor
  public enum CaptureTemporalEvidencePersistence {
    public struct FrameReference: Codable {
      public let recordID: UUID
      public let metadata: DocumentTemporalFrameMetadata

      public init(
        recordID: UUID,
        metadata: DocumentTemporalFrameMetadata
      ) {
        self.recordID = recordID
        self.metadata = metadata
      }
    }

    public struct Sequence: Codable {
      public let observation: DocumentTemporalManifest
      public let frames: [FrameReference]

      public init(
        observation: DocumentTemporalManifest,
        frames: [FrameReference]
      ) {
        self.observation = observation
        self.frames = frames
      }
    }

    public struct Link: Codable {
      public let schemaVersion: Int
      public let recordKind: String
      public let captureID: UUID
      public let sessionID: String
      public let sourceSHA256: String
      public let sequenceID: UUID
      public let sequenceNumber: Int?
      public let payloadSHA256: String

      public init(
        schemaVersion: Int,
        recordKind: String,
        captureID: UUID,
        sessionID: String,
        sourceSHA256: String,
        sequenceID: UUID,
        sequenceNumber: Int? = nil,
        payloadSHA256: String
      ) {
        self.schemaVersion = schemaVersion
        self.recordKind = recordKind
        self.captureID = captureID
        self.sessionID = sessionID
        self.sourceSHA256 = sourceSHA256
        self.sequenceID = sequenceID
        self.sequenceNumber = sequenceNumber
        self.payloadSHA256 = payloadSHA256
      }
    }

    public static func retain(
      _ evidence: DocumentTemporalEvidence, manifest: CaptureRecords.Manifest,
      store: CaptureEvidenceStore
    ) async throws -> CaptureTemporalEvidenceReference {
      try validate(evidence.manifest, original: manifest)
      guard evidence.frames.map(\.metadata) == evidence.manifest.frames else { throw failure }
      let observation = evidence.manifest
      var frames: [FrameReference] = []
      for frame in evidence.frames {
        try Task.checkCancellation()
        try validate(frame.payload, metadata: frame.metadata)
        let id = UUID()
        let link = makeLink(
          "temporalFrame", observation: observation, captureID: manifest.captureID,
          number: frame.metadata.sequenceNumber, hash: frame.metadata.sha256)
        try await store.store(
          id: id, original: frame.payload, manifest: JSONEncoder().encode(link))
        frames.append(.init(recordID: id, metadata: frame.metadata))
      }
      try Task.checkCancellation()
      let data = try JSONEncoder().encode(Sequence(observation: observation, frames: frames))
      let hash = CaptureArtifactIntegrity.sha256(data)
      let link = makeLink(
        "temporalSequence", observation: observation, captureID: manifest.captureID,
        number: nil, hash: hash)
      try await store.store(
        id: observation.sequenceID, original: data, manifest: JSONEncoder().encode(link))
      let reference = CaptureTemporalEvidenceReference(
        schemaVersion: 1, recordID: observation.sequenceID, sha256: hash,
        frameCount: frames.count, motionSampleCount: observation.motionSamples.count,
        status: observation.status)
      var linked = manifest
      linked.temporalEvidence = reference
      _ = try await verify(linked, store: store)
      return reference
    }

    /// Validates every payload and source link, returning only the committed graph's record IDs.
    @discardableResult
    public static func verify(
      _ manifest: CaptureRecords.Manifest, store: CaptureEvidenceStore
    ) async throws -> Set<UUID> {
      guard let reference = manifest.temporalEvidence else { return [] }
      guard reference.schemaVersion == 1 else { throw failure }
      let record = try await store.read(id: reference.recordID)
      guard CaptureArtifactIntegrity.sha256(record.original) == reference.sha256 else {
        throw failure
      }
      let sequence = try JSONDecoder().decode(Sequence.self, from: record.original)
      let observation = sequence.observation
      try validate(observation, original: manifest)
      guard observation.sequenceID == reference.recordID,
        reference.frameCount == sequence.frames.count,
        reference.motionSampleCount == observation.motionSamples.count,
        reference.status == observation.status,
        sequence.frames.map(\.metadata) == observation.frames
      else { throw failure }
      try verifyLink(
        record.manifest,
        expected: makeLink(
          "temporalSequence", observation: observation, captureID: manifest.captureID,
          number: nil, hash: reference.sha256))
      var ids: Set<UUID> = [reference.recordID]
      for frame in sequence.frames {
        try Task.checkCancellation()
        guard frame.recordID != manifest.captureID, ids.insert(frame.recordID).inserted else {
          throw failure
        }
        let retained = try await store.read(id: frame.recordID)
        try verifyLink(
          retained.manifest,
          expected: makeLink(
            "temporalFrame", observation: observation, captureID: manifest.captureID,
            number: frame.metadata.sequenceNumber, hash: frame.metadata.sha256))
        try validate(retained.original, metadata: frame.metadata)
      }
      return ids
    }

    nonisolated private static var failure: CaptureIntegrityError { .integrityVerificationFailed }

    private static func makeLink(
      _ kind: String, observation: DocumentTemporalManifest, captureID: UUID,
      number: Int?, hash: String
    ) -> Link {
      .init(
        schemaVersion: 1, recordKind: kind, captureID: captureID,
        sessionID: observation.binding.sessionID, sourceSHA256: observation.binding.stillSHA256,
        sequenceID: observation.sequenceID, sequenceNumber: number, payloadSHA256: hash)
    }

    private static func verifyLink(_ data: Data, expected: Link) throws {
      let link = try JSONDecoder().decode(Link.self, from: data)
      guard link.schemaVersion == expected.schemaVersion, link.recordKind == expected.recordKind,
        link.captureID == expected.captureID, link.sessionID == expected.sessionID,
        link.sourceSHA256 == expected.sourceSHA256, link.sequenceID == expected.sequenceID,
        link.sequenceNumber == expected.sequenceNumber, link.payloadSHA256 == expected.payloadSHA256
      else { throw failure }
    }

    private static func validate(
      _ observation: DocumentTemporalManifest, original: CaptureRecords.Manifest
    ) throws {
      let binding = observation.binding
      guard observation.schemaVersion == 1, observation.sequenceID != original.captureID,
        binding.sessionID == original.sessionID.rawValue.uuidString,
        binding.attemptID == original.captureID.uuidString,
        binding.side == original.profile.side.rawValue,
        binding.stillSHA256 == original.fidelity.sha256,
        binding.stillTimestamp == original.captureTimestamp,
        observation.configuration.enabled,
        observation.configuration.preCaptureDuration.isFinite,
        observation.configuration.postCaptureDuration.isFinite,
        observation.configuration.preCaptureDuration >= 0,
        observation.configuration.postCaptureDuration >= 0,
        observation.configuration.maximumBytes > 0,
        observation.configuration.maximumFrames > 0,
        observation.configuration.maximumMotionSamples > 0,
        observation.configuration.maximumDiagnostics > 0,
        observation.omittedDiagnosticCount >= 0, observation.evictedFrameCount >= 0,
        observation.evictedMotionSampleCount >= 0,
        ["recorded", "partial"].contains(observation.status),
        observation.frames.count <= observation.configuration.maximumFrames,
        observation.motionSamples.count <= observation.configuration.maximumMotionSamples
      else { throw failure }
      if observation.status == "recorded" {
        guard observation.termination == "completed", observation.issues.isEmpty,
          observation.gaps.isEmpty, observation.omittedDiagnosticCount == 0,
          !observation.frames.isEmpty, !observation.motionSamples.isEmpty,
          observation.clockCorrelation != nil
        else { throw failure }
      }
      try CaptureTemporalObservationContract.verify(observation)
      var totalBytes = 0
      var previous: Int?
      for frame in observation.frames {
        guard frame.sequenceNumber >= 0,
          previous.map({ frame.sequenceNumber > $0 }) ?? true
        else { throw failure }
        for plane in frame.planes {
          guard plane.byteCount > 0,
            plane.byteCount <= observation.configuration.maximumBytes - totalBytes
          else { throw failure }
          totalBytes += plane.byteCount
        }
        previous = frame.sequenceNumber
      }
    }

    public nonisolated static func validate(
      _ payload: Data, metadata: DocumentTemporalFrameMetadata
    ) throws {
      guard metadata.width > 0, metadata.height > 0, !metadata.planes.isEmpty,
        metadata.timestamp.timescale > 0, metadata.timestamp.flags & 1 != 0,
        metadata.timestamp.flags & 28 == 0, metadata.hostTimeSeconds?.isFinite != false,
        CaptureArtifactIntegrity.sha256(payload) == metadata.sha256
      else { throw failure }
      var end = 0
      for plane in metadata.planes {
        guard plane.offset == end, plane.width > 0, plane.height > 0,
          plane.packedBytesPerRow > 0, plane.sourceBytesPerRow >= plane.packedBytesPerRow,
          plane.byteCount > 0, plane.byteCount <= payload.count - end,
          plane.byteCount / plane.height == plane.packedBytesPerRow,
          plane.byteCount.isMultiple(of: plane.height)
        else { throw failure }
        end += plane.byteCount
      }
      guard end == payload.count else { throw failure }
    }
  }
#endif
