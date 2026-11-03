import Foundation

extension DocumentCaptureClockTimestamp {
  var seconds: Double { Double(value) / Double(timescale) }
  var isNumeric: Bool { timescale > 0 && flags & 1 != 0 && flags & 28 == 0 }
}

extension DocumentTemporalFrame {
  var valid: Bool {
    guard metadata.timestamp.isNumeric, metadata.width > 0, metadata.height > 0,
      metadata.sequenceNumber >= 0, metadata.hostTimeSeconds?.isFinite != false,
      metadata.sha256.count == 64, metadata.sha256.allSatisfy(\.isHexDigit),
      !metadata.planes.isEmpty, !payload.isEmpty
    else { return false }
    var expectedOffset = 0
    for plane in metadata.planes {
      guard plane.offset == expectedOffset, plane.width > 0, plane.height > 0,
        plane.packedBytesPerRow > 0, plane.sourceBytesPerRow >= plane.packedBytesPerRow,
        plane.packedBytesPerRow <= Int.max / plane.height,
        plane.byteCount == plane.packedBytesPerRow * plane.height,
        plane.byteCount <= payload.count - expectedOffset
      else { return false }
      expectedOffset += plane.byteCount
    }
    return expectedOffset == payload.count && cameraIsFinite && geometryIsFinite
  }

  private var geometryIsFinite: Bool {
    guard let geometry = metadata.geometry else { return true }
    return geometry.observationTimestamp.isNumeric && geometry.confidence?.isFinite != false
      && (geometry.quadrilateral?.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } ?? true)
  }

  private var cameraIsFinite: Bool {
    guard let camera = metadata.camera else { return true }
    return camera.readbackHostTimeSeconds.isFinite && camera.lensPosition.isFinite
      && camera.exposureDurationSeconds.isFinite
      && camera.iso.isFinite && camera.zoomFactor.isFinite && camera.rotationDegrees.isFinite
  }
}
