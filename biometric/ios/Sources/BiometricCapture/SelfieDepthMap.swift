#if os(iOS)
  import AVFoundation
  import CoreGraphics
  import ImageIO

  /// An owned copy of the depth plane is retained alongside its own ARFrame's capturedImage, never attached to
  /// a later colour-only frame. ARKit supplies it only for front TrueDepth face experiences and
  /// can omit it on intervening colour frames. Rear sceneDepth is deliberately not an input.
  /// https://developer.apple.com/documentation/arkit/arframe/captureddepthdata
  public final class SelfieDepthMap: @unchecked Sendable {
    let data: AVDepthData
    private let sourceWasFiltered: Bool
    let imageTimestamp: TimeInterval
    let depthTimestamp: TimeInterval

    public init(data: AVDepthData, imageTimestamp: TimeInterval, depthTimestamp: TimeInterval) throws {
      sourceWasFiltered = data.isDepthDataFiltered
      let snapshot = try SelfieFrameSnapshot.copy(data.depthDataMap, depth: true)
      do { self.data = try data.replacingDepthDataMap(with: snapshot) }
      catch { throw SelfieFrameSnapshotError.depthCopyFailed }
      self.imageTimestamp = imageTimestamp
      self.depthTimestamp = depthTimestamp
    }

    /// Vision sees the oriented image. Rotate the paired depth by the same EXIF operation, then
    /// flip the normalized Vision bottom-left box to the depth map's top-left coordinates once.
    /// Apple warps depth to the companion YUV lens distortion, allowing normalized image mapping.
    /// https://developer.apple.com/documentation/avfoundation/avdepthdata
    /// https://developer.apple.com/documentation/avfoundation/avdepthdata/applyingexiforientation(_:)
    func measure(
      faceBox: CGRect, orientation: CGImagePropertyOrientation, policy: SelfieDepthPolicy
    ) -> SelfieDepthEvidence {
      let oriented = data.applyingExifOrientation(orientation)
      let converted = oriented.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
      let map = converted.depthDataMap
      let measurement = SelfieDepthEvaluator.measure(
        samples: Self.samples(in: map, faceBox: faceBox, policy: policy), policy: policy)
      return .init(
        schemaVersion: 1, measurement: measurement, imageTimestamp: imageTimestamp,
        depthTimestamp: depthTimestamp, orientation: orientation.rawValue,
        mapWidth: CVPixelBufferGetWidth(map), mapHeight: CVPixelBufferGetHeight(map),
        filtered: sourceWasFiltered, ageAtAdmission: imageTimestamp - depthTimestamp,
        imageSHA256: "")
    }

    static func samples(
      in map: CVPixelBuffer, faceBox: CGRect, policy: SelfieDepthPolicy
    ) -> [SelfieDepthSample] {
      guard policy.isValid,
        CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
        [faceBox.minX, faceBox.maxX, faceBox.minY, faceBox.maxY].allSatisfy({ $0.isFinite }),
        faceBox.width > 0, faceBox.height > 0
      else { return [] }
      let width = CVPixelBufferGetWidth(map)
      let height = CVPixelBufferGetHeight(map)
      guard width > 0, height > 0,
        CVPixelBufferLockBaseAddress(map, .readOnly) == kCVReturnSuccess
      else { return [] }
      defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(map) else { return [] }
      let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.stride
      let values = base.assumingMemoryBound(to: Float32.self)
      // Clamp before conversion, including malformed out-of-image boxes.
      let left = Int(max(0, min(1, faceBox.minX)) * CGFloat(width))
      let right = Int(max(0, min(1, faceBox.maxX)) * CGFloat(width))
      let top = Int(max(0, min(1, 1 - faceBox.maxY)) * CGFloat(height))
      let bottom = Int(max(0, min(1, 1 - faceBox.minY)) * CGFloat(height))
      guard right > left, bottom > top else { return [] }
      let step = max(1, min((right - left) / policy.samplesPerAxis,
                            (bottom - top) / policy.samplesPerAxis))
      // Allocation budget, not a biometric threshold. Refuse pathological aspect ratios or
      // policies before creating samples; never silently change the declared sampling step.
      let sampledColumns = (right - left - 1) / step + 1
      let sampledRows = (bottom - top - 1) / step + 1
      guard sampledRows <= 4_096, sampledColumns <= 4_096 / sampledRows else { return [] }
      var samples: [SelfieDepthSample] = []
      samples.reserveCapacity(sampledColumns * sampledRows)
      for row in Swift.stride(from: top, to: bottom, by: step) {
        for column in Swift.stride(from: left, to: right, by: step) {
          samples.append(.init(x: Double(column), y: Double(row), z: Double(values[row * stride + column])))
        }
      }
      return samples
    }
  }
#endif
