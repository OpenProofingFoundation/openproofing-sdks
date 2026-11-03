import CoreVideo
import Foundation
import DocumentSDK
import Vision

/// Queue-confined native Vision analysis. Payloads are reduced to readability
/// counts before crossing the analysis queue; no recognized content is logged.
final class DocumentLiveContentAnalyzer {
  func analyze(
    _ pixelBuffer: CVPixelBuffer,
    regionOfInterest: CGRect?,
    target: DocumentLiveContentTarget = .documentText
  ) -> DocumentLiveContentMetrics {
    guard let regionOfInterest, !regionOfInterest.isEmpty else { return .empty }
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
    let textRequest = VNRecognizeTextRequest()
    textRequest.regionOfInterest = regionOfInterest
    textRequest.recognitionLevel = .fast
    textRequest.usesLanguageCorrection = false
    textRequest.minimumTextHeight = DocumentCaptureTuning.Readability.minimumLiveTextHeight
    if target == .passportMRZ || target == .passportCardMRZ {
      textRequest.recognitionLanguages = ["en-US"]
    }

    let barcodeRequest = VNDetectBarcodesRequest()
    barcodeRequest.regionOfInterest = regionOfInterest
    let requests: [VNRequest]
    switch target {
    case .documentText: requests = [textRequest, barcodeRequest]
    case .licensePDF417: requests = [barcodeRequest]
    case .passportMRZ, .passportCardMRZ: requests = [textRequest]
    }
    do {
      if target == .documentText || target == .licensePDF417 {
        try DocumentVisionRequests.configurePDF417(barcodeRequest)
      }
      try handler.perform(requests)
    } catch {
      return .empty
    }
    let recognizedText = textRequest.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    let decodedPDF417 = barcodeRequest.results?.compactMap(\.payloadStringValue) ?? []
    return Self.metrics(text: recognizedText, pdf417: decodedPDF417, target: target)
  }

  static func metrics(
    text: [String], pdf417: [String], target: DocumentLiveContentTarget
  ) -> DocumentLiveContentMetrics {
    let text = target == .licensePDF417 ? [] : text
    var pdf417 =
      (target == .passportMRZ || target == .passportCardMRZ) ? [] : pdf417.filter { !$0.isEmpty }
    if target == .licensePDF417,
      pdf417.count != 1 || AAMVAPDF417Parser.parse(pdf417[0]).status != .readable {
      pdf417 = []
    }
    let mrzCandidateCount: Int? =
      (target == .passportMRZ || target == .passportCardMRZ)
      ? 0 : nil
    return DocumentLiveContentMetrics(
      recognizedTextLineCount: text.count,
      recognizedCharacterCount: text.reduce(0) { $0 + $1.count },
      decodedPDF417Count: pdf417.count,
      decodedPDF417CharacterCount: pdf417.map(\.count).max() ?? 0,
      mrzCandidateCount: mrzCandidateCount)
  }
}
