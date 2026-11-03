import Foundation
import Testing
import DocumentSDK
@testable import DocumentCaptureApple

@Suite struct DocumentObservationWireCompatibilityTests {
  @Test func mechanicalReadabilityAndReadinessKeepRetainedFieldNames() throws {
    let retained = Data("""
      {"side":"front","isUsable":true,"failures":[],"recognizedTextLineCount":2,
      "recognizedCharacterCount":40,"decodedPDF417Count":0,"decodedPDF417CharacterCount":0}
      """.utf8)
    let readability = try JSONDecoder().decode(DocumentPhotoUsabilityAssessment.self, from: retained)
    #expect(readability.usable)
    #expect(readability.analysisFailure == nil)
    let object = try encodedObject(readability)
    #expect(object["isUsable"] as? Bool == true)
    #expect(object["usable"] == nil)
    #expect(Set(object.keys) == ["side", "isUsable", "failures", "recognizedTextLineCount",
      "recognizedCharacterCount", "decodedPDF417Count", "decodedPDF417CharacterCount"])
    #expect(try JSONDecoder().decode(DocumentPhotoUsabilityAssessment.self,
      from: JSONEncoder().encode(readability)) == readability)
    let readiness = DocumentCaptureExpectationAssessment.evaluate(expectation: .licenseFront,
      pdf417Payloads: [], usability: readability, completeDocument: true, frontLayoutCandidate: true)
    let ready = try encodedObject(readiness)
    #expect(readiness.outcome == .readableCandidate)
    #expect(ready["recognizedAAMVABack"] as? Bool == false)
    #expect(ready["frontLayoutCandidate"] as? Bool == true)
    #expect(Set(ready.keys) == ["schemaVersion", "expectation", "outcome", "reason",
      "recognizedAAMVABack", "frontLayoutCandidate"])
    #expect(try JSONDecoder().decode(DocumentCaptureExpectationAssessment.self,
      from: JSONEncoder().encode(readiness)) == readiness)
  }

  @Test func opticalLayoutAndRecordingContextKeepRetainedKeys() throws {
    let optical = PhotoFidelityMetadata.OpticalState(focalLengthMillimeters: 6.9,
      focalLengthIn35mmFilm: 24, lensSpecification: [2.2, 6.9, 1.8, 2.8], digitalZoomRatio: 1.2,
      compositeImage: 2, hdrGainMapPresent: true)
    let opticalObject = try encodedObject(optical)
    #expect(Set(opticalObject.keys) == ["focalLengthMillimeters", "focalLengthIn35mmFilm",
      "lensSpecification", "digitalZoomRatio", "compositeImage", "hdrGainMapPresent"])
    #expect(try JSONDecoder().decode(PhotoFidelityMetadata.OpticalState.self,
      from: JSONEncoder().encode(optical)) == optical)
    let layout = DocumentFrontLayoutEvidence.evaluate(recognizedText: ["DRIVER LICENSE"], detectedFaceCount: 1)
    let layoutObject = try encodedObject(layout)
    #expect(Set(layoutObject.keys) == ["detectedFaceCount", "hasDriverTitleToken", "hasLicenseTitleToken"])
    #expect(layoutObject["driverTitleTokenObserved"] == nil)
    #expect(layout.provisionalFrontLayoutCandidate)
    let event = DocumentJourneyRecordingEvent(kind: "session_issue", hostTimeSeconds: 12.5,
      sessionID: "retained-session", contextCode: "interrupted")
    let recording = try encodedObject(event)
    #expect(recording["detail"] as? String == "interrupted")
    #expect(recording["contextCode"] == nil)
    #expect(try JSONDecoder().decode(DocumentJourneyRecordingEvent.self,
      from: JSONEncoder().encode(event)) == event)
    let context = DocumentImageDerivation.ContextCrop(policyVersion: "id1-native-context-bbox75-v1",
      sourcePixelWidth: 400, sourcePixelHeight: 300, left: 20, top: 30, width: 300, height: 200,
      paddingFraction: 0.0773502691896258, clippedToSourceBounds: false)
    #expect(Set(try encodedObject(context).keys) == ["policyVersion", "sourcePixelWidth",
      "sourcePixelHeight", "left", "top", "width", "height", "paddingFraction", "clippedToSourceBounds"])
    #expect(try JSONDecoder().decode(DocumentImageDerivation.ContextCrop.self,
      from: JSONEncoder().encode(context)) == context)
  }

  @Test func sourceCropRetainsRejectedIndicesWithoutInventingCandidate() throws {
    let faces = [PortraitFaceObservation(boundingBox: .init(x: 0.2, y: 0.2, width: 0, height: 0.3), confidence: 1)]
    let crop = PortraitCropPolicy.evaluate(faces: faces, imageWidth: 100, imageHeight: 80)
    #expect(crop.candidates.isEmpty)
    #expect(crop.selectedCandidateIndex == nil)
    #expect(crop.unselectedFaceIndices == [0])
    let object = try encodedObject(crop)
    #expect(object["rejectedFaceIndices"] as? [Int] == [0])
    #expect(object["unselectedFaceIndices"] == nil)
    #expect(object["selectedCandidateIndex"] == nil)
    let retained = try JSONSerialization.data(withJSONObject: object)
    #expect(try JSONDecoder().decode(PortraitCropAssessment.self, from: retained) == crop)
  }

  private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  }
}
