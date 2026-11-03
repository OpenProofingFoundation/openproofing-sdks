import Foundation
import DocumentSDK
import Testing

@Test
func captureSessionIdentifierRoundTripsThroughJSON() throws {
  let rawValue = try #require(
    UUID(uuidString: "EBD69829-194A-4E19-85E7-97A88E291EEE")
  )
  let identifier = CaptureSessionID(
    rawValue: rawValue
  )

  let encoded = try JSONEncoder().encode(identifier)
  let decoded = try JSONDecoder().decode(CaptureSessionID.self, from: encoded)

  #expect(decoded == identifier)
}

@Test
func importedMediaIsNotLiveCapture() {
  #expect(MediaOrigin.imported != .liveSensor)
}
