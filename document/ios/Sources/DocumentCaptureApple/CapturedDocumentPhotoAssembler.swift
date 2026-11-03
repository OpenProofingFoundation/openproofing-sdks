import CoreMedia
import Foundation
import DocumentSDK
import ImageIO

extension DocumentCaptureClockTimestamp {
  init?(avCapturePhotoTimestamp timestamp: CMTime) {
    guard timestamp.isNumeric else { return nil }
    self.init(
      value: timestamp.value,
      timescale: timestamp.timescale,
      flags: timestamp.flags.rawValue,
      epoch: timestamp.epoch,
      clock: .captureSessionSynchronizationClock
    )
  }
}

struct CapturedDocumentPhotoAssembler: Sendable {
  private let now: @Sendable () -> Date

  init(now: @escaping @Sendable () -> Date) {
    self.now = now
  }

  func assemble(
    data: Data,
    sessionID: CaptureSessionID,
    side: DocumentSide,
    captureTimestamp: DocumentCaptureClockTimestamp,
    requestedAt: Date? = nil,
    admission: DocumentCaptureAdmissionSnapshot? = nil,
    locationAssertion: CaptureLocationAssertion? = nil,
    captureMetadata: CapturedPhotoPlatformMetadata.Serialized = .none
  ) throws -> CapturedDocumentPhoto {
    let processedAt = now()
    // The retained bytes are read once. Copying the property dictionary is not
    // free and each auxiliary probe materializes that auxiliary image's
    // payload, so every record below shares one source, one property
    // dictionary and one probe rather than repeating them.
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CapturedPhotoPlatformMetadata.encodedProperties(of: source)
    else {
      throw PhotoCaptureError.imageMetadataUnavailable
    }
    let auxiliaryDataTypes = CapturedPhotoPlatformMetadata.auxiliaryTypes(of: source)

    return CapturedDocumentPhoto(
      sessionID: sessionID,
      side: side,
      requestedAt: requestedAt ?? processedAt,
      captureTimestamp: captureTimestamp,
      processedAt: processedAt,
      data: data,
      fidelity: try PhotoFidelityMetadata.make(
        from: data, source: source, properties: properties,
        auxiliaryDataTypes: auxiliaryDataTypes),
      admission: admission,
      platformMetadata: CapturedPhotoPlatformMetadata.make(
        properties: properties, auxiliaryDataTypes: auxiliaryDataTypes,
        captureMetadata: captureMetadata),
      location: locationAssertion.map { assertion in
        Self.locationRecord(for: assertion, properties: properties)
      }
    )
  }

  /// Confirms from the retained bytes whether the requested location was
  /// written, rather than assuming it because it was requested.
  private static func locationRecord(
    for assertion: CaptureLocationAssertion,
    properties: [CFString: Any]
  ) -> CaptureLocationRecord {
    guard assertion.wellFormed else {
      return CaptureLocationRecord(
        assertion: assertion, disposition: .refusedMalformedAssertion)
    }
    guard CaptureLocationGPSMetadata.encodedPropertiesCarry(assertion, properties: properties)
    else {
      return CaptureLocationRecord(
        assertion: assertion, disposition: .requestedButAbsentFromEncodedBytes)
    }
    return CaptureLocationRecord(
      assertion: assertion, disposition: .embeddedInEncodedBytes)
  }
}
