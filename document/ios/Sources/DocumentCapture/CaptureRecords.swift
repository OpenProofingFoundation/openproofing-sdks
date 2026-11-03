#if os(iOS)
  public enum CaptureRecords {}
  import Foundation
  import DocumentCaptureApple
  import DocumentSDK
  import DocumentCaptureJournal

  extension CaptureRecords {
    public enum Profile: String, CaseIterable, Identifiable, Codable, Sendable {
      case licenseFront = "license_front"
      case licenseBack = "license_back"
      case passportCardFront = "passport_card_front"
      case passportCardBack = "passport_card_back"
      case passport = "passport_page"
      case document = "document"
      /// New records use stable codes. Historical title-shaped identifiers are read-only aliases.
      /// Original signed manifest bytes remain in custody and are never rewritten by decoding.
      public static func retainedIdentifier(_ identifier: String) -> Self? {
        if let value = Self(rawValue: identifier) { return value }
        guard identifier.contains(" ") else { return nil }
        let legacy = identifier.replacingOccurrences(of: " ", with: "_")
        switch legacy {
        case "License_front": return .licenseFront
        case "License_back": return .licenseBack
        case "US_passport_card_front": return .passportCardFront
        case "US_passport_card_back": return .passportCardBack
        case "Passport_page": return .passport
        case "Other_document": return .document
        default: return nil
        }
      }

      public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let identifier = try container.decode(String.self)
        guard let value = Self.retainedIdentifier(identifier) else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "capture_profile_unsupported")
        }
        self = value
      }

      public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
      }

      public var id: String { rawValue }
      public var side: DocumentSide { backSide ? .back : .front }
      public var backSide: Bool { self == .licenseBack || self == .passportCardBack }
      public var twoSided: Bool { self == .licenseFront || self == .passportCardFront }
      public var frontProfile: Self {
        self == .passportCardBack
          ? .passportCardFront : (self == .licenseBack ? .licenseFront : self)
      }
      public var backProfile: Self {
        switch self {
        case .passportCardFront, .passportCardBack: .passportCardBack
        case .licenseFront, .licenseBack: .licenseBack
        case .passport, .document: self
        }
      }
      // Passport-card MRZ validation runs on the retained full-resolution still.
      public var requiresLiveContent: Bool { self == .licenseBack || self == .passport }
      public var liveContentTarget: DocumentLiveContentTarget {
        switch self {
        case .licenseBack: .licensePDF417
        case .passport: .passportMRZ
        case .passportCardBack: .passportCardMRZ
        case .licenseFront, .passportCardFront, .document: .documentText
        }
      }
    }

    public struct Manifest: Codable {
      public let schemaVersion: Int
      public let captureID: UUID
      public let profile: Profile
      public let sessionID: CaptureSessionID
      public let captureTimestamp: DocumentCaptureClockTimestamp
      public let processedAt: Date
      public let fidelity: PhotoFidelityMetadata
      public let admission: DocumentCaptureAdmissionSnapshot?
      /// Recorded acquisition path, not a hardware attestation or document-authenticity claim.
      /// Nil means historical provenance was not recorded; never infer live origin on decode.
      public var origin: MediaOrigin?
      /// Live metadata observation; authority requires equality with a unique decode
      /// of this retained original. This is not an authenticity claim.
      public var livePDF417Candidate: String?
      public var side: String?
      public var journeyRecording: CaptureRecordingReference?
      public var journeyBindingVersion: Int?
      public var temporalEvidence: CaptureTemporalEvidenceReference?
      public let motionStatus: String
      public let workflowID: UUID?
      public let precedingFrontCaptureID: UUID?
      public var journeyRevision: UInt64?
      /// Complete numerical configuration active for this source; absent on older captures.
      public var captureTuning: [String: Double]?
      public var tuningProfileIdentifier: String?
      public var tuningCalibrationStatus: String?
      /// Complete platform metadata retained alongside the curated `fidelity`
      /// subset. Nil on manifests written before it was recorded.
      public var platformMetadata: CapturedPhotoPlatformMetadata?
      /// Host-supplied location and its disposition. Nil when no location was
      /// supplied by older captures. This host now requires capture-time location.
      public var location: CaptureLocationRecord?
      /// The presence policy that applied to this still (S-02), and whether it gated it or only
      /// observed tilt. Nil when no policy applied, including every capture made before the check
      /// existed.
      public var documentPresence: CaptureDocumentPresenceRecord?

      public init(
        schemaVersion: Int,
        captureID: UUID,
        profile: Profile,
        sessionID: CaptureSessionID,
        captureTimestamp: DocumentCaptureClockTimestamp,
        processedAt: Date,
        fidelity: PhotoFidelityMetadata,
        admission: DocumentCaptureAdmissionSnapshot? = nil,
        journeyRecording: CaptureRecordingReference? = nil,
        journeyBindingVersion: Int? = nil,
        temporalEvidence: CaptureTemporalEvidenceReference? = nil,
        motionStatus: String,
        workflowID: UUID? = nil,
        precedingFrontCaptureID: UUID? = nil,
        journeyRevision: UInt64? = nil,
        captureTuning: [String: Double]? = nil,
        platformMetadata: CapturedPhotoPlatformMetadata? = nil,
        location: CaptureLocationRecord? = nil
      ) {
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.profile = profile
        self.sessionID = sessionID
        self.captureTimestamp = captureTimestamp
        self.processedAt = processedAt
        self.fidelity = fidelity
        self.admission = admission
        self.journeyRecording = journeyRecording
        self.journeyBindingVersion = journeyBindingVersion
        self.temporalEvidence = temporalEvidence
        self.motionStatus = motionStatus
        self.workflowID = workflowID
        self.precedingFrontCaptureID = precedingFrontCaptureID
        self.journeyRevision = journeyRevision
        self.captureTuning = captureTuning
        self.platformMetadata = platformMetadata
        self.location = location
      }
    }

    public struct ExtractionManifest: Codable {
      public let schemaVersion: Int
      public let recordKind: String
      public let captureID: UUID
      public let sourceSHA256: String

      public init(
        schemaVersion: Int,
        recordKind: String,
        captureID: UUID,
        sourceSHA256: String
      ) {
        self.schemaVersion = schemaVersion
        self.recordKind = recordKind
        self.captureID = captureID
        self.sourceSHA256 = sourceSHA256
      }
    }

    public struct DerivativeManifest: Codable {
      public let schemaVersion: Int
      public let recordKind: String
      public let captureID: UUID
      public let sourceSHA256: String
      public let derivation: DocumentImageDerivation

      public init(
        schemaVersion: Int,
        recordKind: String,
        captureID: UUID,
        sourceSHA256: String,
        derivation: DocumentImageDerivation
      ) {
        self.schemaVersion = schemaVersion
        self.recordKind = recordKind
        self.captureID = captureID
        self.sourceSHA256 = sourceSHA256
        self.derivation = derivation
      }
    }
  }
#endif
