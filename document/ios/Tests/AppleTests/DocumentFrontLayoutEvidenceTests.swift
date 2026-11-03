import Foundation
import Testing

@testable import DocumentCaptureApple

@Test func frontLayoutRequiresOneFaceAndExplicitEnglishTitle() {
  for title in ["DRIVER LICENSE", "Drivers Licence", "Driver’s License"] {
    #expect(layout(title, faces: 1).provisionalFrontLayoutCandidate)
    #expect(!layout(title, faces: 0).provisionalFrontLayoutCandidate)
    #expect(!layout(title, faces: 2).provisionalFrontLayoutCandidate)
    #expect(!layout(title, faces: nil).provisionalFrontLayoutCandidate)
  }
}

@Test func genericBackAndUnsupportedTitlesRemainUnknown() {
  for text in [
    "Name Address Date of Birth", "AAMVA PDF417 Restrictions Endorsements",
    "DRIVER", "LICENSE", "PASSPORT", "IDENTIFICATION CARD", "PERMIS DE CONDUIRE",
    "DRIVERSLICENSE", "DRIVERSHIP LICENSER"
  ] {
    #expect(!layout(text, faces: 1).provisionalFrontLayoutCandidate)
  }
}

@Test func frontLayoutEvidenceRoundTripsWithoutAnAuthenticityVerdict() throws {
  let evidence = layout("DRIVER LICENSE", faces: 1)
  let data = try JSONEncoder().encode(evidence)
  #expect(try JSONDecoder().decode(DocumentFrontLayoutEvidence.self, from: data) == evidence)
}

private func layout(_ text: String, faces: Int?) -> DocumentFrontLayoutEvidence {
  DocumentFrontLayoutEvidence.evaluate(recognizedText: [text], detectedFaceCount: faces)
}

@Test func legacyExtractionWithoutFaceObservationsRemainsDecodable() throws {
  let legacy = """
    {"schemaVersion":1,"fidelity":{"pixelWidth":1,"pixelHeight":1,"fileByteCount":1,
    "uniformTypeIdentifier":"public.jpeg","sha256":"retained-original-hash"},
    "imagePropertiesPlist":"","pdf417Payloads":[],"recognizedText":["DRIVER LICENSE"],
    "barcodeRequestRevision":1,"textRequestRevision":1}
    """
  let extraction = try JSONDecoder().decode(ArtifactExtraction.self, from: Data(legacy.utf8))
  #expect(extraction.detectedFaceCount == nil)
  #expect(extraction.faceRequestRevision == nil)
  #expect(
    !DocumentFrontLayoutEvidence.evaluate(
      recognizedText: extraction.recognizedText,
      detectedFaceCount: extraction.detectedFaceCount
    ).provisionalFrontLayoutCandidate)
}
