import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

@Test func expectationBackRequiresStructuredPayloadAndCompleteUsablePhoto() {
  let good = assessment(.licenseBack, payloads: [licensePayload()])
  #expect(good.outcome == .readableCandidate)
  #expect(good.reason == .supportedBackCandidate)
  #expect(good.recognizedAAMVABack)
  #expect(
    assessment(.licenseBack, payloads: [licensePayload()], complete: false).outcome
      == .insufficientEvidence)
  #expect(
    assessment(.licenseBack, payloads: [licensePayload()], usable: false).outcome
      == .insufficientEvidence)
  #expect(
    assessment(.licenseBack, payloads: [String(repeating: "X", count: 100)]).outcome
      == .insufficientEvidence)
}

@Test func expectationRecognizedBackRefusesFrontEvenWithGenericFrontSignal() {
  for front in [false, true] {
    let value = assessment(.licenseFront, payloads: [licensePayload()], front: front)
    #expect(value.outcome == .wrongSide)
    #expect(value.reason == .backPresentedForFront)
  }
}

@Test func expectationFrontRequiresExplicitLayoutEvidenceNotAbsentBarcodeOrOCRCounts() {
  let unknown = assessment(.licenseFront)
  #expect(unknown.outcome == .insufficientEvidence)
  #expect(unknown.reason == .frontLayoutUnconfirmed)
  #expect(assessment(.licenseFront, payloads: ["not AAMVA"]).outcome == .insufficientEvidence)
  let candidate = assessment(.licenseFront, front: true)
  #expect(candidate.outcome == .readableCandidate)
  #expect(candidate.reason == .provisionalFrontCandidate)
  #expect(assessment(.licenseFront, front: true, complete: false).outcome == .insufficientEvidence)
  #expect(assessment(.licenseBack, front: true).outcome == .wrongSide)
}

@Test func expectationConflictingBackSignalsAndMismatchedUsabilityNeverPass() {
  let conflicting = assessment(.licenseBack, payloads: [licensePayload()], front: true)
  #expect(conflicting.outcome == .insufficientEvidence)
  #expect(conflicting.reason == .conflictingLayoutSignals)
  let mismatch = DocumentCaptureExpectationAssessment.evaluate(
    expectation: .licenseBack, pdf417Payloads: [licensePayload()],
    usability: usability(.front), completeDocument: true)
  #expect(mismatch.outcome == .insufficientEvidence)
}

@Test func expectationExtractionFailureAndUnsupportedProfilesRemainExplicit() {
  let failed = assessment(.licenseBack, payloads: [licensePayload()], front: true, extracted: false)
  #expect(failed.outcome == .extractionFailed)
  #expect(!failed.recognizedAAMVABack)
  #expect(!failed.frontLayoutCandidate)
  #expect(assessment(.document, payloads: [licensePayload()], front: true).outcome == .notAssessed)
  #expect(
    assessment(.passport, payloads: [licensePayload()], front: true).outcome
      == .notAssessed)
}

@Test func expectationRejectsMalformedTruncatedDuplicateAndUnsupportedPayloads() {
  let valid = licensePayload()
  let malformed = [
    String(valid.dropLast()),
    valid.replacingOccurrences(of: "DL0031", with: "DL0032"),
    valid.replacingOccurrences(of: "636000090001", with: "636000120001"),
    valid.replacingOccurrences(of: "@\n\u{1e}\r", with: "@\n\r"),
    licensePayload(extra: "DCSOTHER\n"),
    licensePayload(omit: "DAQ")
  ]
  for payload in malformed {
    let value = assessment(.licenseBack, payloads: [payload])
    #expect(!value.recognizedAAMVABack)
    #expect(value.outcome == .insufficientEvidence)
  }
}

@Test func expectationSupportedVersionsAndRecognitionDoNotValidateIdentityValues() {
  // Every AAMVA version the parser reads, for a licence and a state ID, as pulse-ios reads them
  // (owner decision 2026-10-09).
  for version in 1...11 {
    for subfile in ["DL", "ID"] {
      let payload = licensePayload(version: version, subfile: subfile)
      #expect(assessment(.licenseBack, payloads: [payload]).recognizedAAMVABack)
    }
  }
  // Recognition intentionally checks envelope/element structure, not actual names/dates or issuers.
  #expect(assessment(.licenseBack, payloads: [licensePayload()]).reason == .supportedBackCandidate)
}

@Test func expectationAssessmentRoundTripsWithoutRetainingBarcodePayload() throws {
  let value = assessment(.licenseBack, payloads: [licensePayload()])
  let data = try JSONEncoder().encode(value)
  #expect(try JSONDecoder().decode(DocumentCaptureExpectationAssessment.self, from: data) == value)
  let encoded = try #require(String(data: data, encoding: .utf8))
  #expect(!encoded.contains("ANSI"))
}

private func assessment(
  _ expectation: DocumentCaptureExpectation, payloads: [String] = [], front: Bool = false,
  complete: Bool = true, usable: Bool = true, extracted: Bool = true
) -> DocumentCaptureExpectationAssessment {
  DocumentCaptureExpectationAssessment.evaluate(
    expectation: expectation, pdf417Payloads: payloads,
    usability: usability(expectation == .licenseBack ? .back : .front, usable: usable),
    completeDocument: complete, frontLayoutCandidate: front, extractionSucceeded: extracted)
}

private func usability(_ side: DocumentSide, usable: Bool = true)
  -> DocumentPhotoUsabilityAssessment {
  DocumentPhotoUsabilityAssessment(
    side: side, usable: usable, failures: usable ? [] : [.completeDocumentNotDetected],
    recognizedTextLineCount: 100, recognizedCharacterCount: 1000,
    decodedPDF417Count: 1, decodedPDF417CharacterCount: 100)
}

private func licensePayload(
  version: Int = 9, extra: String = "", omit: String? = nil, subfile: String = "DL"
) -> String {
  let codes = [
    "DCA", "DCB", "DCD", "DBA", "DCS", "DAC", "DAD", "DBD", "DBB", "DBC", "DAY",
    "DAU", "DAG", "DAI", "DAJ", "DAK", "DAQ", "DCF", "DCG", "DDE", "DDF", "DDG"
  ]
  let body = subfile + codes.filter { $0 != omit }.map { $0 + "SAMPLE\n" }.joined() + extra + "\r"
  // Version 01 headers carry no jurisdiction version field.
  let header =
    "@\n\u{1e}\rANSI 636000" + String(format: "%02d", version) + (version == 1 ? "" : "00") + "01"
  return header + subfile + String(format: "%04d%04d", header.utf8.count + 10, body.utf8.count)
    + body
}

@Test(arguments: [DocumentCaptureExpectation.passport, .passportCardFront, .passportCardBack])
func passportProfilesRequireIndependentCapability(_ profile: DocumentCaptureExpectation) {
  let value = DocumentCaptureExpectationAssessment.evaluate(
    expectation: profile, pdf417Payloads: [licensePayload()], usability: usability(.front),
    completeDocument: true, frontLayoutCandidate: true)
  #expect(value.outcome == .notAssessed)
  #expect(value.reason == .unsupportedProfile)
  #expect(value.expectation == profile)
}
