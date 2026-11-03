import Foundation
import DocumentSDK

public enum DocumentCaptureExpectation: String, Codable, Sendable {
  case licenseFront, licenseBack, passport, document, passportCardFront, passportCardBack
}

/// Provisional layout/readability evidence, never identity, issuer validation or authenticity.
public struct DocumentCaptureExpectationAssessment: Codable, Equatable, Sendable {
  public enum Outcome: String, Codable, Sendable {
    case readableCandidate, wrongSide, insufficientEvidence, notAssessed, extractionFailed
  }

  public enum Reason: String, Codable, Sendable {
    case supportedBackCandidate, provisionalFrontCandidate, backPresentedForFront,
      frontPresentedForBack
    case conflictingLayoutSignals, frontLayoutUnconfirmed, supportedBackNotRecognized
    case completeUsablePhotoRequired, unsupportedProfile, extractionUnavailable
    case readablePassportMRZ, passportMRZNotReadable
    case passportCardFrontCandidate, readablePassportCardMRZ, passportCardNotReadable
  }

  public let schemaVersion: Int
  public let expectation: DocumentCaptureExpectation
  public let outcome: Outcome
  public let reason: Reason
  public let recognizedAAMVABack: Bool
  public let frontLayoutCandidate: Bool

  /// All inputs must describe the same retained source (including any linked derivative).
  /// Complete-document evidence must come from still preparation, not barcode decoding.
  /// Front-layout evidence is supplied by a separately versioned observer, never inferred
  /// here from absent PDF417 or a quantity of generic OCR text.
  public static func evaluate(
    expectation: DocumentCaptureExpectation, pdf417Payloads: [String],
    usability: DocumentPhotoUsabilityAssessment?, completeDocument: Bool,
    frontLayoutCandidate: Bool = false, extractionSucceeded: Bool = true
  ) -> Self {
    let back =
      extractionSucceeded
      && pdf417Payloads.contains { AAMVAPDF417Parser.parse($0).status == .readable }
    let front = extractionSucceeded && frontLayoutCandidate
    let expectedSide: DocumentSide =
      expectation == .licenseBack || expectation == .passportCardBack ? .back : .front
    let completeUsable =
      completeDocument && usability?.side == expectedSide
      && usability?.usable == true && usability?.failures.isEmpty == true
    let decision = decide(
      expectation: expectation, back: back, front: front, completeUsable: completeUsable,
      extractionSucceeded: extractionSucceeded)
    return Self(
      schemaVersion: 1, expectation: expectation, outcome: decision.0, reason: decision.1,
      recognizedAAMVABack: back, frontLayoutCandidate: front)
  }

  private static func decide(
    expectation: DocumentCaptureExpectation, back: Bool, front: Bool,
    completeUsable: Bool, extractionSucceeded: Bool
  ) -> (Outcome, Reason) {
    guard extractionSucceeded else { return (.extractionFailed, .extractionUnavailable) }
    guard expectation == .licenseFront || expectation == .licenseBack else {
      return (.notAssessed, .unsupportedProfile)
    }
    if expectation == .licenseFront && back { return (.wrongSide, .backPresentedForFront) }
    if back && front { return (.insufficientEvidence, .conflictingLayoutSignals) }
    if expectation == .licenseBack && front { return (.wrongSide, .frontPresentedForBack) }
    guard completeUsable else {
      return (.insufficientEvidence, .completeUsablePhotoRequired)
    }
    if expectation == .licenseBack {
      return back
        ? (.readableCandidate, .supportedBackCandidate)
        : (.insufficientEvidence, .supportedBackNotRecognized)
    }
    return front
      ? (.readableCandidate, .provisionalFrontCandidate)
      : (.insufficientEvidence, .frontLayoutUnconfirmed)
  }
}
