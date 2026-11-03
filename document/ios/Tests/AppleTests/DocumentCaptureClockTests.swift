import CoreMedia
import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

@Test
func captureTimestampPreservesExactSessionClockComponentsAndCodableProvenance() throws {
  let source = CMTime(
    value: 12_345,
    timescale: 600,
    flags: CMTimeFlags(rawValue: 3),
    epoch: 7
  )
  let timestamp = try #require(
    DocumentCaptureClockTimestamp(avCapturePhotoTimestamp: source)
  )

  #expect(timestamp.value == source.value)
  #expect(timestamp.timescale == source.timescale)
  #expect(timestamp.flags == source.flags.rawValue)
  #expect(timestamp.epoch == source.epoch)
  #expect(timestamp.clock == .captureSessionSynchronizationClock)

  let encoded = try JSONEncoder().encode(timestamp)
  let decoded = try JSONDecoder().decode(DocumentCaptureClockTimestamp.self, from: encoded)
  #expect(decoded == timestamp)
}

@Test
func invalidCaptureTimestampIsUnavailable() {
  #expect(
    DocumentCaptureClockTimestamp(avCapturePhotoTimestamp: .invalid) == nil
  )
  #expect(PhotoCaptureError.captureTimestampUnavailable.code == "capture_timestamp_unavailable")
}
