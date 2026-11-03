import AVFoundation
import Foundation

extension DocumentTemporalRecorder {
  struct FrameSnapshot {
    let generation: UInt64
    let ringGeneration: UInt64
    let sequence: Int
    let hostTime: Double?
    let camera: DocumentTemporalCameraState?
    let sink: (any DocumentJourneyRecordingSink)?
    let retainRing: Bool
    let callbackTicket: UInt64?
  }

  struct FrameContext {
    let snapshot: FrameSnapshot
    let geometry: DocumentTemporalGeometry?
    let rotation: Double
    let mirrored: Bool
  }

  func append(
    _ sample: CMSampleBuffer, geometry: DocumentTemporalGeometry?,
    rotationDegrees: Double, mirrored: Bool
  ) {
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    guard let timestamp = DocumentCaptureClockTimestamp(avCapturePhotoTimestamp: time),
      let pixels = CMSampleBufferGetImageBuffer(sample)
    else {
      withState {
        if running {
          buffer.recordIssue("video_timestamp_or_image_unavailable")
          emit(
            .init(
              kind: "frame_invalid", hostTimeSeconds: Self.hostNow(),
              contextCode: "video_timestamp_or_image_unavailable"))
        }
      }
      return
    }
    do {
      let bytes = try DocumentTemporalPixelCopy.byteCount(pixels)
      guard let snapshot = frameSnapshot(time: time, timestamp: timestamp, byteCount: bytes)
      else { return }
      defer { if let ticket = snapshot.callbackTicket { finishSinkCallback(ticket) } }
      let reservation = snapshot.sink?.reserveFrame(byteCount: bytes,
        failure: .init(kind: "frame_admission_failed", hostTimeSeconds: Self.hostNow(),
          timestamp: timestamp, contextCode: "sink_capacity_or_termination"))
      guard reservation != nil || snapshot.retainRing else { return }
      copyAndCommit(
        pixels, timestamp: timestamp, byteCount: bytes,
        context: FrameContext(
          snapshot: snapshot, geometry: geometry, rotation: rotationDegrees, mirrored: mirrored),
        reservation: reservation)
    } catch {
      withState {
        if running {
          buffer.recordGap(
            .init(reason: "native_frame_copy_failed", timestamp: timestamp, count: 1))
          emit(
            .init(
              kind: "frame_copy_failed", hostTimeSeconds: Self.hostNow(),
              timestamp: timestamp, contextCode: String(describing: error)))
        }
      }
    }
  }

  private func copyAndCommit(
    _ pixels: CVPixelBuffer, timestamp: DocumentCaptureClockTimestamp,
    byteCount: Int, context: FrameContext, reservation: UUID?
  ) {
    let snapshot = context.snapshot
    do {
      let copy = try pixelCopier(pixels, byteCount)
      let frame = DocumentTemporalFrame(
        metadata: frameMetadata(
          pixels: pixels, timestamp: timestamp, copy: copy,
          context: context
        ), payload: copy.data)
      commit(frame, snapshot: snapshot, reservation: reservation, copy: copy)
    } catch {
      if let reservation {
        snapshot.sink?.cancelReservation(reservation,
          failure: .init(kind: "frame_copy_failed", hostTimeSeconds: Self.hostNow(),
            timestamp: timestamp, contextCode: String(describing: error)))
      }
      withState {
        if ringGeneration == snapshot.ringGeneration {
          buffer.recordGap(
            .init(reason: "native_frame_copy_failed", timestamp: timestamp, count: 1))
        }
      }
    }
  }

  private func frameSnapshot(
    time: CMTime, timestamp: DocumentCaptureClockTimestamp, byteCount: Int
  ) -> FrameSnapshot? {
    withState {
      guard running else { return nil }
      sequence += 1
      // The journey sink is offered a frame only once the minimum interval has
      // passed since the last one it was offered; the ring below is not paced.
      // A timestamp that stood still or went backwards is always offered: that
      // is a clock discontinuity the journal records, and a new epoch must not
      // be starved by a stale marker.
      let sink: (any DocumentJourneyRecordingSink)?
      if let journeySink {
        let due =
          lastAdmittedJourneySeconds.map {
            timestamp.seconds - $0 >= journeyPacing.minimumFrameIntervalSeconds || timestamp.seconds <= $0
          } ?? true
        if due { lastAdmittedJourneySeconds = timestamp.seconds }
        sink = due ? journeySink : nil
      } else {
        sink = nil
      }
      return FrameSnapshot(
        generation: frameGeneration, ringGeneration: ringGeneration,
        sequence: sequence, hostTime: hostSeconds(time), camera: camera, sink: sink,
        retainRing: buffer.prepareForFrame(byteCount: byteCount),
        callbackTicket: sink == nil ? nil : beginSinkCallback())
    }
  }

  private func commit(
    _ frame: DocumentTemporalFrame, snapshot: FrameSnapshot,
    reservation: UUID?, copy: DocumentTemporalPixelCopy.Copy
  ) {
    let valid = withState {
      guard running, frameGeneration == snapshot.generation else { return false }
      if snapshot.camera == nil {
        recordJourneyIssue("camera_readback_unavailable", timestamp: frame.metadata.timestamp)
      }
      if copy.attachmentSerializationFailed {
        recordJourneyIssue(
          "video_color_attachments_serialization_failed", timestamp: frame.metadata.timestamp)
      }
      if snapshot.retainRing && ringGeneration == snapshot.ringGeneration { buffer.append(frame) }
      if reservation != nil { validateJourneyFrame(frame) }
      return true
    }
    guard let reservation else { return }
    if valid {
      snapshot.sink?.appendFrame(frame, reservation: reservation)
    } else {
      snapshot.sink?.cancelReservation(reservation,
        failure: .init(kind: "frame_copy_cancelled", hostTimeSeconds: Self.hostNow(),
          timestamp: frame.metadata.timestamp, contextCode: "capture_generation_changed_during_copy"))
    }
  }

  func attachRingGeometry(_ geometry: DocumentTemporalGeometry) {
    guard
      let index = buffer.frames.firstIndex(where: {
        $0.metadata.timestamp == geometry.observationTimestamp
      })
    else { return }
    let original = buffer.frames[index]
    let metadata = original.metadata
    buffer.frames[index] = DocumentTemporalFrame(
      metadata: DocumentTemporalFrameMetadata(
        sequenceNumber: metadata.sequenceNumber, timestamp: metadata.timestamp,
        hostTimeSeconds: metadata.hostTimeSeconds, width: metadata.width, height: metadata.height,
        pixelFormat: metadata.pixelFormat, planes: metadata.planes, sha256: metadata.sha256,
        colorAttachmentsPlist: metadata.colorAttachmentsPlist, geometry: geometry,
        camera: metadata.camera),
      payload: original.payload)
  }

  private func recordJourneyIssue(_ reason: String, timestamp: DocumentCaptureClockTimestamp) {
    buffer.recordIssue(reason)
    emit(
      .init(
        kind: "frame_issue", hostTimeSeconds: Self.hostNow(),
        timestamp: timestamp, contextCode: reason))
  }

  private func frameMetadata(
    pixels: CVPixelBuffer, timestamp: DocumentCaptureClockTimestamp,
    copy: DocumentTemporalPixelCopy.Copy,
    context: FrameContext
  ) -> DocumentTemporalFrameMetadata {
    DocumentTemporalFrameMetadata(
      sequenceNumber: context.snapshot.sequence, timestamp: timestamp,
      hostTimeSeconds: context.snapshot.hostTime, width: CVPixelBufferGetWidth(pixels),
      height: CVPixelBufferGetHeight(pixels), pixelFormat: CVPixelBufferGetPixelFormatType(pixels),
      planes: copy.planes, sha256: copy.sha256, colorAttachmentsPlist: copy.attachments,
      geometry: context.geometry,
      camera: context.snapshot.camera.map {
        DocumentTemporalCameraState(
          readbackHostTimeSeconds: $0.readbackHostTimeSeconds,
          geometryRevision: $0.geometryRevision, opticalRevision: $0.opticalRevision,
          focusModeRawValue: $0.focusModeRawValue, exposureModeRawValue: $0.exposureModeRawValue,
          deviceUniqueID: $0.deviceUniqueID, lensPosition: $0.lensPosition,
          exposureDurationSeconds: $0.exposureDurationSeconds, iso: $0.iso,
          zoomFactor: $0.zoomFactor, adjustingFocus: $0.adjustingFocus,
          adjustingExposure: $0.adjustingExposure, rotationDegrees: context.rotation,
          mirrored: context.mirrored)
      })
  }

  func dropped(_ sample: CMSampleBuffer) {
    withState {
      guard running else { return }
      let reason =
        CMGetAttachment(
          sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
          attachmentModeOut: nil
        ).map { String(describing: $0) } ?? "unknown"
      emit(
        .init(
          kind: "frame_dropped", hostTimeSeconds: Self.hostNow(),
          timestamp: DocumentCaptureClockTimestamp(
            avCapturePhotoTimestamp: CMSampleBufferGetPresentationTimeStamp(sample)),
          contextCode: reason))
      buffer.recordGap(
        DocumentTemporalGap(
          reason: "avfoundation_\(reason)",
          timestamp: DocumentCaptureClockTimestamp(
            avCapturePhotoTimestamp: CMSampleBufferGetPresentationTimeStamp(sample)), count: 1))
    }
  }
}
