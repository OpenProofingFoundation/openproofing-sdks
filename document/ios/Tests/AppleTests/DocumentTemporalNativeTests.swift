import AVFoundation
import CryptoKit
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

struct DocumentTemporalNativeTests {
  @Test func analysisOwnsPixelsAfterCaptureBufferChanges() throws {
    let source = try pixels()
    let owned = try #require(DocumentAnalysisPixelCopy.copy(source))
    #expect(owned !== source)
    #expect(CVPixelBufferLockBaseAddress(source, []) == kCVReturnSuccess)
    for plane in 0..<2 {
      let base = try #require(CVPixelBufferGetBaseAddressOfPlane(source, plane))
      memset(base, 0, CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane))
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    let retained = try DocumentTemporalPixelCopy.copy(owned, maximumBytes: 10000)
    #expect(retained.data == Data(repeating: 42, count: 768))
  }

  @Test func packsNativePlanesWithoutPaddingOrResampling() throws {
    let pixels = try pixels()
    let copy = try DocumentTemporalPixelCopy.copy(pixels, maximumBytes: 10000)
    #expect(copy.data.count == 32 * 16 * 3 / 2)
    #expect(copy.data == Data(repeating: 42, count: 32 * 16 * 3 / 2))
    #expect(copy.planes.map(\.packedBytesPerRow) == [32, 32])
    #expect(copy.planes[1].offset == 512)
    #expect(copy.planes[0].sourceBytesPerRow >= 64)
    #expect(copy.sha256 == SHA256.hash(data: copy.data).map { String(format: "%02x", $0) }.joined())
  }

  @Test func refusesOversizeNativeFrameBeforeAllocation() throws {
    let pixels = try pixels()
    #expect(throws: DocumentTemporalPixelCopy.Failure.capacity) {
      try DocumentTemporalPixelCopy.copy(pixels, maximumBytes: 767)
    }
  }

  @Test func stopAndRejectedRestartPreserveOriginalCaptureClock() throws {
    let recorder = DocumentTemporalRecorder(configuration: .init(enabled: true))
    recorder.start(clock: CMClockGetHostTimeClock())
    let time = DocumentTemporalRecorder.hostNow()
    recorder.beginCapture()
    recorder.append(try sample(at: time), geometry: nil, rotationDegrees: 90, mirrored: false)
    recorder.stop()
    // Restart cannot replace the correlation or reuse a pending sequence.
    recorder.start(clock: nil)
    recorder.append(try sample(at: time + 0.1), geometry: nil, rotationDegrees: 90, mirrored: false)
    let result = recorder.finish(try photo(at: time))
    #expect(result.frames.count == 1)
    #expect(result.manifest.binding.stillHostTimeSeconds != nil)
    #expect(result.manifest.termination == "session_stopped")
    #expect(result.manifest.issues.contains("restart_rejected_pending_sequence"))
    #expect(result.manifest.issues.contains("session_stopped_during_sequence"))
    #expect(result.manifest.status == "partial")
  }

  @Test func abandonedCaptureCannotContaminateNextSequence() throws {
    let recorder = DocumentTemporalRecorder(configuration: .init(enabled: true))
    recorder.start(clock: CMClockGetHostTimeClock())
    defer { recorder.stop() }
    let time = DocumentTemporalRecorder.hostNow()
    recorder.beginCapture()
    recorder.append(try sample(at: time), geometry: nil, rotationDegrees: 90, mirrored: false)
    recorder.abandonCapture()
    recorder.beginCapture()
    recorder.append(try sample(at: time + 0.1), geometry: nil, rotationDegrees: 90, mirrored: false)
    let result = recorder.finish(try photo(at: time + 0.1))
    #expect(result.frames.map(\.metadata.sequenceNumber) == [2])
    #expect(result.frames.first?.metadata.geometry == nil)
  }

  @Test func changedSessionClockCannotRebindPendingStill() throws {
    let recorder = DocumentTemporalRecorder(configuration: .init(enabled: true))
    recorder.start(clock: CMClockGetHostTimeClock())
    let time = DocumentTemporalRecorder.hostNow()
    recorder.beginCapture()
    recorder.append(try sample(at: time), geometry: nil, rotationDegrees: 90, mirrored: false)
    recorder.clockDidChange(to: nil)
    // Even if it changes back, the pending association remains indeterminate.
    recorder.clockDidChange(to: CMClockGetHostTimeClock())
    recorder.append(try sample(at: time + 0.1), geometry: nil, rotationDegrees: 90, mirrored: false)
    let result = recorder.finish(try photo(at: time))
    #expect(result.frames.count == 1)
    #expect(result.frames.first?.metadata.hostTimeSeconds != nil)
    #expect(result.manifest.binding.stillHostTimeSeconds == nil)
    #expect(result.manifest.termination == "session_clock_changed")
    #expect(result.manifest.issues.contains("session_clock_changed_during_sequence"))
    #expect(result.manifest.status == "partial")
    recorder.stop()
  }

  @Test func missingSessionClockRemainsExplicit() throws {
    let recorder = DocumentTemporalRecorder(configuration: .init(enabled: true))
    recorder.start(clock: nil)
    defer { recorder.stop() }
    recorder.beginCapture()
    let time = DocumentTemporalRecorder.hostNow()
    recorder.append(try sample(at: time), geometry: nil, rotationDegrees: 0, mirrored: false)
    let result = recorder.finish(try photo(at: time))
    #expect(result.manifest.binding.stillHostTimeSeconds == nil)
    #expect(result.frames.first?.metadata.hostTimeSeconds == nil)
    #expect(result.manifest.status == "partial")
    #expect(result.manifest.issues.contains("session_clock_unavailable"))
  }

  private func pixels() throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, 32, 16,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary, &buffer)
    #expect(status == kCVReturnSuccess)
    let pixels = try #require(buffer)
    #expect(CVPixelBufferLockBaseAddress(pixels, []) == kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
    for plane in 0..<2 {
      let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, plane)
      let height = CVPixelBufferGetHeightOfPlane(pixels, plane)
      let width = CVPixelBufferGetWidthOfPlane(pixels, plane) * (plane == 0 ? 1 : 2)
      memset(base, 238, stride * height)
      for row in 0..<height { memset(base.advanced(by: row * stride), 42, width) }
    }
    return pixels
  }

  private func sample(at seconds: Double) throws -> CMSampleBuffer {
    let pixels = try pixels()
    var format: CMVideoFormatDescription?
    #expect(
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format) == noErr
    )
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixels, formatDescription: try #require(format),
        sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    return try #require(sample)
  }

  private func photo(at seconds: Double) throws -> CapturedDocumentPhoto {
    CapturedDocumentPhoto(
      sessionID: CaptureSessionID(), side: .front,
      requestedAt: Date(),
      captureTimestamp: try #require(
        DocumentCaptureClockTimestamp(
          avCapturePhotoTimestamp: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))),
      processedAt: Date(), data: Data([1]),
      fidelity: PhotoFidelityMetadata(
        pixelWidth: 32, pixelHeight: 16, fileByteCount: 1, uniformTypeIdentifier: "public.heic",
        orientation: 1, cameraModel: nil, lensModel: nil, exposureTimeSeconds: nil,
        fNumber: nil, isoSpeed: nil, sha256: String(repeating: "a", count: 64), optical: nil),
      admission: nil)
  }
}
