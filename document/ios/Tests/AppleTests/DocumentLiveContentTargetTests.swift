import Foundation
import DocumentSDK
import Testing

@testable import DocumentCaptureApple

private let specimenMRZ = [
  "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<",
  "L898902C36UTO7408122F1204159ZE184226B<<<<<10"
]

@Test
func passportReadinessRequiresIndependentCapability() {
  let policy = DocumentAutoCaptureContentPolicy()
  let readable = DocumentLiveContentAnalyzer.metrics(
    text: specimenMRZ, pdf417: [], target: .passportMRZ)
  #expect(readable.mrzCandidateCount == 0)
  #expect(readable.recognizedTextLineCount == specimenMRZ.count)
  #expect(!policy.hasUsableSignal(for: .front, metrics: readable, target: .passportMRZ))
  let ordinary = DocumentLiveContentAnalyzer.metrics(
    text: Array(repeating: "PASSPORT PERSONAL DETAILS", count: 8), pdf417: [], target: .passportMRZ)
  #expect(ordinary.mrzCandidateCount == 0)
  #expect(!policy.hasUsableSignal(for: .front, metrics: ordinary, target: .passportMRZ))
  var malformed = specimenMRZ
  malformed[1] = "L898902C30UTO7408122F1204159ZE184226B<<<<<10"
  let rejected = DocumentLiveContentAnalyzer.metrics(
    text: malformed, pdf417: [], target: .passportMRZ)
  #expect(rejected.mrzCandidateCount == 0)
}

@Test
func targetedMetricsDoNotAdmitTheOtherDocumentSignal() {
  let barcode = String(repeating: "X", count: 60)
  let passport = DocumentLiveContentAnalyzer.metrics(
    text: [], pdf417: [barcode], target: .passportMRZ)
  #expect(passport.decodedPDF417Count == 0)
  #expect(passport.mrzCandidateCount == 0)
  let back = DocumentLiveContentAnalyzer.metrics(
    text: specimenMRZ, pdf417: [], target: .licensePDF417)
  #expect(back.recognizedTextLineCount == 0)
  #expect(back.mrzCandidateCount == nil)
  let policy = DocumentAutoCaptureContentPolicy()
  #expect(!policy.hasUsableSignal(for: .back, metrics: back, target: .licensePDF417))
  let multiple = DocumentLiveContentAnalyzer.metrics(
    text: [], pdf417: [barcode, barcode], target: .licensePDF417)
  #expect(!policy.hasUsableSignal(for: .back, metrics: multiple, target: .licensePDF417))
  let single = DocumentLiveContentAnalyzer.metrics(
    text: [], pdf417: [barcode], target: .licensePDF417)
  #expect(!policy.hasUsableSignal(for: .back, metrics: single, target: .licensePDF417))
  let codes = [
    "DCA", "DCB", "DCD", "DBA", "DCS", "DAC", "DAD", "DBD", "DBB", "DBC", "DAY",
    "DAU", "DAG", "DAI", "DAJ", "DAK", "DAQ", "DCF", "DCG", "DDE", "DDF", "DDG"
  ]
  let body = "DL" + codes.map { $0 + "SYNTHETIC\n" }.joined() + "\r"
  let payload = "@\n\u{1e}\rANSI 636000090001DL0031" + String(format: "%04d", body.utf8.count) + body
  let valid = DocumentLiveContentAnalyzer.metrics(
    text: [], pdf417: [payload], target: .licensePDF417)
  #expect(policy.hasUsableSignal(for: .back, metrics: valid, target: .licensePDF417))
}

@Test
func liveContentCodingPreservesLegacyUnknownMRZAndContainsNoRecognizedValues() throws {
  let legacy = Data(
    """
    {"recognizedTextLineCount":2,"recognizedCharacterCount":88,
    "decodedPDF417Count":0,"decodedPDF417CharacterCount":0}
    """.utf8)
  #expect(
    try JSONDecoder().decode(DocumentLiveContentMetrics.self, from: legacy).mrzCandidateCount == nil
  )
  let metrics = DocumentLiveContentAnalyzer.metrics(
    text: specimenMRZ, pdf417: [], target: .passportMRZ)
  let encoded = try JSONEncoder().encode(metrics)
  let json = try #require(String(data: encoded, encoding: .utf8))
  #expect(!json.contains("ERIKSSON"))
  #expect(!json.contains("L898902C3"))
  #expect(try JSONDecoder().decode(DocumentLiveContentMetrics.self, from: encoded) == metrics)
}

@Test
func mrzReadabilityDoesNotBypassCameraAndQualityReadiness() {
  var coordinator = DocumentAutoCaptureCoordinator(
    requireQualityReadiness: true, contentTarget: .passportMRZ,
    frontRequiredConsecutiveObservations: 1)
  coordinator.begin(side: .front)
  let metrics = DocumentLiveContentAnalyzer.metrics(
    text: specimenMRZ, pdf417: [], target: .passportMRZ)
  let observation = DocumentCaptureQualityObservation(
    sequence: 1, geometryRevision: 1, timestamp: Date(),
    metrics: DocumentCaptureQualityMetrics(
      documentFillRatio: nil, documentGuideFillRatio: nil, documentInsideGuide: nil,
      guideCenterX: nil, guideCenterY: nil, guideWidth: nil, guideHeight: nil,
      documentAspectRatio: nil, sharpness: 0, motion: nil, clippedHighlightRatio: 0,
      meanLuminance: 0.5, documentCenterX: nil, documentCenterY: nil),
    assessment: DocumentCaptureQualityAssessment(
      ready: false, blockingReasons: [.documentNotFound], stableFrameCount: 0),
    liveContent: metrics)
  #expect(coordinator.observe(side: .front, observation: observation) == .observing)
}
