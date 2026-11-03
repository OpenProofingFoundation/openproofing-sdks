import Foundation
import Testing

@testable import DocumentCaptureApple

@Test
func extractionRejectsNonImageInput() {
  #expect(throws: PhotoCaptureError.imageMetadataUnavailable) {
    try ArtifactExtraction.extract(original: Data("not an image".utf8))
  }
}

@Test func extractionSchemaOneAndTwoDecodeWithoutInventingNewResults() throws {
  let fidelity = PhotoFidelityMetadata(
    pixelWidth: 100, pixelHeight: 60, fileByteCount: 20, uniformTypeIdentifier: "public.png",
    orientation: 1, cameraModel: nil, lensModel: nil, exposureTimeSeconds: nil,
    fNumber: nil, isoSpeed: nil, sha256: "synthetic", optical: nil)
  let current = ArtifactExtraction(
    schemaVersion: 3, fidelity: fidelity, imagePropertiesPlist: Data(), pdf417Payloads: ["raw"],
    recognizedText: ["retained OCR"], barcodeRequestRevision: 1, textRequestRevision: 1,
    detectedFaceCount: 1, faceRequestRevision: 1, parsedPDF417: [], licenseFront: nil)
  let encoded = try JSONEncoder().encode(current)
  for version in [1, 2] {
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json["schemaVersion"] = version
    json.removeValue(forKey: "parsedPDF417")
    json.removeValue(forKey: "passportMRZ")
    if version == 1 {
      json.removeValue(forKey: "detectedFaceCount")
      json.removeValue(forKey: "faceRequestRevision")
    }
    let decoded = try JSONDecoder().decode(
      ArtifactExtraction.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.schemaVersion == version)
    #expect(decoded.pdf417Payloads == ["raw"])
    #expect(decoded.recognizedText == ["retained OCR"])
    #expect(decoded.parsedPDF417 == nil)
    #expect(decoded.licenseFront == nil)
    #expect(decoded.structuredDocument == nil)
    #expect(decoded.detectedFaceCount == (version == 1 ? nil : 1))
  }
}
