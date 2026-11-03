import Foundation
import DocumentCaptureApple
import CaptureEvidenceCustody

public enum CaptureRecordingVerification {
  public struct Result: Sendable {
    public let ids: Set<UUID>
    public let status: String
    public let stillIDs: Set<UUID>
  }
  struct Counts {
    var profileSides: [String: String] = [:]
    var previousFrame: DocumentTemporalFrameMetadata?
    var latestLiveGeometry: DocumentLiveGeometryObservation?
    var tiltRevisions: [UUID: UInt64] = [:]
    var tiltConfigurations: [UUID: DocumentTiltConfiguration] = [:]
    var previousMotion: Double?
    var frames = 0
    var motion = 0
    var issues = 0
    var stills = 0
    var stillIDs: Set<UUID> = []
    var status = "interrupted"
    var sealed = false
  }

  public static func verify(
    _ reference: CaptureRecordingReference, store: CaptureEvidenceStore,
    profileSides: [String: String] = [:]
  ) async throws -> Result {
    let links = try await loadLinks(reference, store: store)
    var previous: (UUID, String)?
    var counts = Counts()
    counts.profileSides = profileSides
    for ordinal in 0..<links.count {
      try Task.checkCancellation()
      guard let (id, link) = links[ordinal], !counts.sealed,
        link.previousID == previous?.0, link.previousSHA256 == previous?.1
      else { throw CaptureEvidenceStoreError.integrityFailure }
      let record = try await store.read(id: id)
      guard link.payloadSHA256 == (await CaptureTemporalPayload.sha256(record.original)) else {
        throw CaptureEvidenceStoreError.integrityFailure
      }
      try await inspect(record, link: link, reference: reference, store: store, counts: &counts)
      previous = (id, link.payloadSHA256)
    }
    guard previous != nil else { throw CaptureEvidenceStoreError.integrityFailure }
    return Result(
      ids: Set(links.values.map { $0.0 }).union(counts.stillIDs),
      status: counts.status, stillIDs: counts.stillIDs)
  }

  public static func verifyStart(
    manifestData: Data, store: CaptureEvidenceStore
  ) async throws {
    let manifest = try JSONDecoder().decode(CaptureRecordingStillManifest.self, from: manifestData)
    guard let reference = manifest.journeyRecording else { return }
    guard manifest.workflowID == reference.workflowID else {
      throw CaptureEvidenceStoreError.integrityFailure
    }
    let record = try await store.read(id: reference.recordingID)
    let link = try JSONDecoder().decode(CaptureRecordingLink.self, from: record.manifest)
    guard link.schemaVersion == 1, link.recordKind == "journeyRecordingStart", link.ordinal == 0,
      link.recordingID == reference.recordingID, link.workflowID == reference.workflowID,
      link.payloadSHA256 == reference.startSHA256,
      (await CaptureTemporalPayload.sha256(record.original)) == reference.startSHA256,
      link.previousID == nil, link.previousSHA256 == nil
    else { throw CaptureEvidenceStoreError.integrityFailure }
  }

  private static func loadLinks(
    _ reference: CaptureRecordingReference, store: CaptureEvidenceStore
  ) async throws -> [Int: (UUID, CaptureRecordingLink)] {
    let ids = try await store.matchingRecordIDs(recordingID: reference.recordingID)
    var links: [Int: (UUID, CaptureRecordingLink)] = [:]
    for id in ids {
      let manifest = try await store.metadata(id: id)
      let link = try JSONDecoder().decode(CaptureRecordingLink.self, from: manifest)
      guard link.schemaVersion == 1, link.recordingID == reference.recordingID,
        link.workflowID == reference.workflowID, link.ordinal >= 0,
        links[link.ordinal] == nil
      else { throw CaptureEvidenceStoreError.integrityFailure }
      links[link.ordinal] = (id, link)
    }
    return links
  }

  private static func inspect(
    _ record: CaptureEvidenceRecord, link: CaptureRecordingLink,
    reference: CaptureRecordingReference, store: CaptureEvidenceStore,
    counts: inout Counts
  ) async throws {
    switch link.recordKind {
    case "journeyRecordingStart":
      guard link.ordinal == 0, record.id == reference.recordingID,
        link.payloadSHA256 == reference.startSHA256
      else { throw CaptureEvidenceStoreError.integrityFailure }
      let start = try JSONDecoder().decode(
        CaptureRecordingStart.self, from: record.original)
      guard start.schemaVersion == 1 else { throw CaptureEvidenceStoreError.integrityFailure }
    case "journeyRecordingFrame":
      guard link.ordinal > 0, let metadata = link.frame else {
        throw CaptureEvidenceStoreError.integrityFailure
      }
      try await CaptureTemporalPayload.validate(record.original, metadata: metadata)
      try verifyFrameOrder(metadata, counts: &counts)
      counts.frames += 1
    case "journeyRecordingMotion":
      try verifyMotion(record.original, counts: &counts)
    case "journeyRecordingEvent":
      let event = try JSONDecoder().decode(
        DocumentJourneyRecordingEvent.self, from: record.original)
      try await inspectEvent(event, reference: reference, store: store, counts: &counts)
    case "journeyRecordingSeal":
      try verifySeal(record.original, counts: &counts)
    default: throw CaptureEvidenceStoreError.integrityFailure
    }
  }

  private static func inspectEvent(
    _ event: DocumentJourneyRecordingEvent, reference: CaptureRecordingReference,
    store: CaptureEvidenceStore, counts: inout Counts
  ) async throws {
    try verifyTilt(event, counts: &counts)
    if let live = event.liveGeometry {
      guard event.kind == "geometry", live.valid,
        event.geometry == live.geometry, event.timestamp == live.captureTimestamp
      else { throw CaptureEvidenceStoreError.integrityFailure }
    }
    if event.kind == "geometry" { counts.latestLiveGeometry = event.liveGeometry }
    if ["session_started", "clock_epoch_started", "clock_changed"].contains(event.kind) {
      counts.latestLiveGeometry = nil
      counts.previousFrame = nil
      counts.previousMotion = nil
    }
    if event.kind == "frame_issue", event.contextCode == "frame_clock_discontinuity" {
      counts.previousFrame = nil
    }
    if event.kind == "motion_issue", event.contextCode == "motion_clock_discontinuity" {
      counts.previousMotion = nil
    }
    if event.kind == "still_retained" {
      let stillID = try await verifyStill(
        event, reference: reference, store: store, profileSides: counts.profileSides)
      counts.stillIDs.insert(stillID)
      counts.stills += 1
    }
    counts.issues += isIssue(event.kind) ? 1 : 0
  }
}

extension CaptureRecordingVerification {
  private static func verifyTilt(
    _ event: DocumentJourneyRecordingEvent, counts: inout Counts
  ) throws {
    if let tilt = event.tiltGuidance {
      guard event.kind == "tilt_guidance", tilt.valid, tilt.event != nil,
        event.timestamp == tilt.event?.captureTimestamp,
        event.geometry == nil, event.liveGeometry == nil
      else { throw CaptureEvidenceStoreError.integrityFailure }
      let previousRevision = counts.tiltRevisions[tilt.presentation.runID] ?? 0
      guard previousRevision < UInt64.max, tilt.presentation.revision == previousRevision + 1 else {
        throw CaptureEvidenceStoreError.integrityFailure
      }
      if previousRevision == 0 {
        counts.tiltConfigurations[tilt.presentation.runID] = tilt.event?.configuration
      }
      guard let retained = counts.tiltConfigurations[tilt.presentation.runID],
        tilt.event?.configurationVersion == retained.version,
        tilt.event?.configuration.map({ $0 == retained }) ?? true
      else { throw CaptureEvidenceStoreError.integrityFailure }
      counts.tiltRevisions[tilt.presentation.runID] = tilt.presentation.revision
      if let source = tilt.event?.observation {
        guard source == counts.latestLiveGeometry else {
          throw CaptureEvidenceStoreError.integrityFailure
        }
      }
    } else if event.kind == "tilt_guidance" {
      throw CaptureEvidenceStoreError.integrityFailure
    }
  }

  private static func verifyFrameOrder(
    _ frame: DocumentTemporalFrameMetadata, counts: inout Counts
  ) throws {
    if let previous = counts.previousFrame {
      guard frame.sequenceNumber > previous.sequenceNumber,
        frame.timestamp.epoch == previous.timestamp.epoch,
        Double(frame.timestamp.value) / Double(frame.timestamp.timescale)
          > Double(previous.timestamp.value) / Double(previous.timestamp.timescale)
      else { throw CaptureEvidenceStoreError.integrityFailure }
    }
    counts.previousFrame = frame
  }

  private static func verifyMotion(_ data: Data, counts: inout Counts) throws {
    let samples = try JSONDecoder().decode([DocumentTemporalMotionSample].self, from: data)
    guard samples.count <= 100 else { throw CaptureEvidenceStoreError.integrityFailure }
    for sample in samples {
      let values =
        [sample.bootTimeSeconds, sample.attitude.x, sample.attitude.y]
        + [sample.attitude.z, sample.attitude.w, sample.rotationRate.x]
        + [sample.rotationRate.y, sample.rotationRate.z]
        + [sample.gravity.x, sample.gravity.y, sample.gravity.z]
        + [sample.userAcceleration.x, sample.userAcceleration.y, sample.userAcceleration.z]
      guard values.allSatisfy(\.isFinite),
        counts.previousMotion.map({ sample.bootTimeSeconds > $0 }) ?? true
      else { throw CaptureEvidenceStoreError.integrityFailure }
      counts.previousMotion = sample.bootTimeSeconds
    }
    counts.motion += samples.count
  }

  nonisolated static func isIssue(_ kind: String) -> Bool {
    switch kind {
    case "session_started", "session_stopped", "geometry", "still_capture", "still_retained",
      "front", "turnover", "back", "cta", "camera_session_bound", "clock_epoch_started",
      "document_capture_started", "turnover_started", "back_capture_started",
      "front_still_retained", "back_still_retained", "turnover_requested", "capture_review",
      "back_requested", "back_capture_armed", "document_capture_completed", "configuration_changed",
      "retake_requested", "tilt_guidance", "turnover_optional_prompt", "turnover_optional_end":
      return false
    default: return true
    }
  }

  private static func verifySeal(_ data: Data, counts: inout Counts) throws {
    let seal = try JSONDecoder().decode(CaptureRecordingSeal.self, from: data)
    guard seal.frameCount == counts.frames, seal.motionSampleCount == counts.motion,
      seal.issueCount == counts.issues, seal.retainedStillCount == counts.stills,
      ["complete", "partial"].contains(seal.status), seal.refusedFrames >= 0,
      seal.refusedMotionSamples >= 0
    else { throw CaptureEvidenceStoreError.integrityFailure }
    guard seal.acquisitionDiagnostics?.valid != false,
      (seal.coalescedGapEvents ?? 0) >= 0, (seal.platformDropCallbacks ?? 0) >= 0,
      seal.firstLossHostTimeSeconds.map(\.isFinite) ?? true
    else {
      throw CaptureEvidenceStoreError.integrityFailure
    }
    if seal.status == "complete" {
      guard seal.firstLossReason == nil, seal.firstLossTimestamp == nil,
        seal.firstLossHostTimeSeconds == nil,
        (seal.coalescedGapEvents ?? 0) == 0,
        (seal.platformDropCallbacks ?? 0) == 0,
        seal.reason == "completed", seal.refusedFrames == 0, seal.refusedMotionSamples == 0,
        counts.issues == 0, counts.frames > 0, counts.motion > 0, counts.stills > 0
      else { throw CaptureEvidenceStoreError.integrityFailure }
    }
    counts.sealed = true
    counts.status = seal.status
  }

  private static func verifyStill(
    _ event: DocumentJourneyRecordingEvent, reference: CaptureRecordingReference,
    store: CaptureEvidenceStore, profileSides: [String: String]
  ) async throws -> UUID {
    guard let binding = event.binding,
      let attempt = binding.attemptID.flatMap(UUID.init(uuidString:))
    else {
      throw CaptureEvidenceStoreError.integrityFailure
    }
    let still = try await store.read(id: attempt)
    let manifest = try JSONDecoder().decode(
      CaptureRecordingStillManifest.self, from: still.manifest)
    guard manifest.captureID == attempt, manifest.journeyRecording == reference,
      manifest.fidelity.sha256 == binding.stillSHA256,
      (await CaptureTemporalPayload.sha256(still.original)) == binding.stillSHA256,
      manifest.captureTimestamp == binding.stillTimestamp,
      manifest.sessionID.rawValue.uuidString == binding.sessionID,
      (manifest.side ?? profileSides[manifest.profile]) == binding.side
    else { throw CaptureEvidenceStoreError.integrityFailure }
    return attempt
  }
}
