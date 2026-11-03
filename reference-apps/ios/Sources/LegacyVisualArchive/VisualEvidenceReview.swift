import Foundation



/// Optional scalar-only progress. No image, prompt or model output is exposed.


public struct VisualOutputValidationIssue: Sendable {
    public enum Reason: String, Sendable {
        case jsonSyntax, schema, decoding, auraUnavailable, ageUnavailable, ageRange
        case duplicateIndicator, sourceBinding, temporalUnavailable, depthUnavailable
    }
    public let path: String
    public let reason: Reason
}

/// Structural counts only; this never retains generated text.
public struct VisualOutputDiagnostic: Sendable {
    public let bytes: Int
    public let whitespaceBytes: Int
    public let trailingWhitespaceBytes: Int
    public let openObjects: Int
    public let openArrays: Int
    public let insideString: Bool

    init(_ text: String) {
        var whitespace = 0
        var trailing = 0
        var objects = 0
        var arrays = 0
        var quoted = false
        var escaped = false
        for byte in text.utf8 {
            if byte == 9 || byte == 10 || byte == 13 || byte == 32 {
                whitespace += 1
                trailing += 1
            } else { trailing = 0 }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else {
                switch byte {
                case 34: quoted = true
                case 123: objects += 1
                case 125: objects -= 1
                case 91: arrays += 1
                case 93: arrays -= 1
                default: break
                }
            }
        }
        bytes = text.utf8.count
        whitespaceBytes = whitespace
        trailingWhitespaceBytes = trailing
        openObjects = objects
        openArrays = arrays
        insideString = quoted
    }
}

/// Bounded model observations for operator review, never an identity or PAD verdict.
public struct VisualEvidenceReview: Decodable, Sendable {
    public enum ImageQualityIssue: String, Decodable, Sendable {
        case blur, underexposure, overexposure, occlusion, glare
        case unevenLighting = "uneven_lighting"
        case offAngle = "off_angle"
        case lowDetail = "low_detail"
        case partialFace = "partial_face"
    }
    public struct ApparentAge: Decodable, Sendable {
        public let rangeYears: [Int]?
        public let basis: String
        public let limitations: [String]
    }
    public struct ImageReview: Decodable, Sendable {
        public let qualityIssues: [ImageQualityIssue]
        public let observations: [String]
        public let apparentAge: ApparentAge
    }
    public enum AuraRelationship: String, Decodable, Sendable {
        case supports, tension
        case notAssessable = "not_assessable"
    }
    public struct AuraReview: Decodable, Sendable {
        public let relationship: AuraRelationship
        public let evidence: [String]
        public let limitations: [String]
    }
    public enum AgeRelationship: String, Decodable, Sendable {
        case plausible
        case raisesQuestion = "raises_question"
        case notAssessable = "not_assessable"
    }
    public struct AgeReview: Decodable, Sendable {
        public let relationship: AgeRelationship
        public let evidence: [String]
        public let limitations: [String]
    }
    public enum IndicatorKind: String, Decodable, Sendable {
        case moire
        case screenTexture = "screen_texture"
        case visibleBezel = "visible_bezel"
        case paperTexture = "paper_texture"
        case printedEdges = "printed_edges"
        case faceSceneInconsistency = "face_scene_inconsistency"
        case possibleManipulationArtifacts = "possible_manipulation_artifacts"
        case motionParallax = "motion_parallax"
        case highlightMotion = "highlight_motion"
        case replayMotion = "replay_motion"
        case cameraMotionConsistency = "camera_motion_consistency"
        case depthConsistency = "depth_consistency"
    }
    public enum IndicatorStatus: String, Decodable, Sendable {
        case present, absent
        case notObservable = "not_observable"
    }
    public struct Indicator: Decodable, Sendable {
        public let indicator: IndicatorKind
        public let status: IndicatorStatus
        public let evidence: String
        public let sourceImageIds: [String]
    }
    public struct CaptureReview: Decodable, Sendable {
        public let indicators: [Indicator]
        public let observations: [String]
        public let limitations: [String]
    }
    public let reference: ImageReview
    public let selfie: ImageReview
    public let auraReview: AuraReview
    public let ageReview: AgeReview
    public let captureReview: CaptureReview
    public let summary: String

    static func parse(_ data: Data, schema: ReviewJSON, depthAvailable: Bool, auraAvailable: Bool = false,
                      onInvalid: ((VisualOutputValidationIssue) -> Void)? = nil) throws -> Self {
        func reject(_ reason: VisualOutputValidationIssue.Reason, _ path: String) throws -> Never {
            onInvalid?(VisualOutputValidationIssue(path: path, reason: reason))
            throw VisualFaceAssessmentFailure.invalidOutput
        }
        let json: ReviewJSON
        do { json = try ReviewJSON.parse(data, maximumBytes: LiquidReviewProfile.maximumOutputBytes) }
        catch { try reject(.jsonSyntax, "$") }
        try ReviewSchema.validate(json, schema: schema, report: {
            onInvalid?(VisualOutputValidationIssue(path: $0, reason: .schema))
        })
        let decoded: Self
        do { decoded = try JSONDecoder().decode(Self.self, from: data) }
        catch { try reject(.decoding, "$") }
        if !auraAvailable && decoded.auraReview.relationship != .notAssessable {
            try reject(.auraUnavailable, "$.auraReview.relationship")
        }
        if decoded.ageReview.relationship != .notAssessable {
            try reject(.ageUnavailable, "$.ageReview.relationship")
        }
        for image in [decoded.reference, decoded.selfie] {
            if let age = image.apparentAge.rangeYears, age[0] > age[1] {
                try reject(.ageRange, "$.apparentAge.rangeYears")
            }
        }
        let indicators = decoded.captureReview.indicators
        guard Set(indicators.map { $0.indicator.rawValue }).count == indicators.count else {
            try reject(.duplicateIndicator, "$.captureReview.indicators")
        }
        let temporal: Set<IndicatorKind> = [.motionParallax, .highlightMotion, .replayMotion, .cameraMotionConsistency]
        for (index, indicator) in indicators.enumerated() {
            let path = "$.captureReview.indicators[\(index)]"
            if !indicator.sourceImageIds.allSatisfy({ $0 == "Media-2" }) { try reject(.sourceBinding, path + ".sourceImageIds") }
            if temporal.contains(indicator.indicator) && indicator.status != .notObservable {
                try reject(.temporalUnavailable, path + ".status")
            }
            if indicator.indicator == .depthConsistency && !depthAvailable && indicator.status != .notObservable {
                try reject(.depthUnavailable, path + ".status")
            }
        }
        return decoded
    }
}

public struct VisualEvidenceReviewObservation: Sendable {
    public let referenceSHA256: String
    public let selfieSHA256: String
    public let artifactSHA256: String
    public let profileID: String
    public let contextSHA256: String
    public let promptContractSHA256: String
    public let promptSHA256: String
    public let responseSchemaSHA256: String
    public let durationMilliseconds: Double
    public let review: VisualEvidenceReview
}

/// Strict validation for the closed JSON Schema vocabulary used by the pinned
/// resources. Shape checks run after guided generation; grammar alone is weaker.
enum ReviewSchema {
    static func validate(_ value: ReviewJSON, schema: ReviewJSON, depth: Int = 0,
                         path: String = "$", report: ((String) -> Void)? = nil) throws {
        do { try validateBody(value, schema: schema, depth: depth, path: path, report: report) }
        catch { report?(path); throw error }
    }

    private static func validateBody(_ value: ReviewJSON, schema: ReviewJSON, depth: Int,
                                     path: String, report: ((String) -> Void)?) throws {
        guard depth <= 32 else { throw VisualFaceAssessmentFailure.invalidOutput }
        if let boolean = schema.bool {
            guard boolean else { throw VisualFaceAssessmentFailure.invalidOutput }; return
        }
        guard let rules = schema.object else { throw VisualFaceAssessmentFailure.invalidOutput }
        if let options = rules["anyOf"]?.array {
            guard options.contains(where: { (try? validate(value, schema: $0, depth: depth + 1)) != nil }) else {
                throw VisualFaceAssessmentFailure.invalidOutput
            }
        }
        if let options = rules["oneOf"]?.array {
            guard options.filter({ (try? validate(value, schema: $0, depth: depth + 1)) != nil }).count == 1 else {
                throw VisualFaceAssessmentFailure.invalidOutput
            }
        }
        if let forbidden = rules["not"], (try? validate(value, schema: forbidden, depth: depth + 1)) != nil {
            throw VisualFaceAssessmentFailure.invalidOutput
        }
        if let constant = rules["const"], try constant.encoded() != value.encoded() {
            throw VisualFaceAssessmentFailure.invalidOutput
        }
        if let enumeration = rules["enum"]?.array {
            let encoded = try value.encoded()
            guard try enumeration.contains(where: { try $0.encoded() == encoded }) else {
                throw VisualFaceAssessmentFailure.invalidOutput
            }
        }
        if let type = rules["type"]?.string {
            let matches: Bool
            switch type {
            case "object": matches = value.object != nil
            case "array": matches = value.array != nil
            case "string": matches = value.string != nil
            case "number": matches = value.number != nil
            case "integer": matches = value.number.map { $0.rounded(.towardZero) == $0 } ?? false
            case "boolean": matches = value.bool != nil
            case "null": matches = value.isNull
            default: matches = false
            }
            guard matches else { throw VisualFaceAssessmentFailure.invalidOutput }
        }
        if let object = value.object {
            let properties = rules["properties"]?.object ?? [:]
            let required = rules["required"]?.array?.compactMap(\.string) ?? []
            guard required.allSatisfy({ object[$0] != nil }),
                  rules["additionalProperties"]?.bool != false || Set(object.keys).isSubset(of: Set(properties.keys)) else {
                throw VisualFaceAssessmentFailure.invalidOutput
            }
            for (key, child) in object {
                if let childSchema = properties[key] {
                    try validate(child, schema: childSchema, depth: depth + 1, path: path + "." + key, report: report)
                }
            }
        }
        if let array = value.array {
            try bounded(Double(array.count), minimum: rules["minItems"]?.number, maximum: rules["maxItems"]?.number)
            if rules["uniqueItems"]?.bool == true {
                guard try Set(array.map { try $0.encoded() }).count == array.count else {
                    throw VisualFaceAssessmentFailure.invalidOutput
                }
            }
            if let itemSchema = rules["items"] {
                for (index, child) in array.enumerated() {
                    try validate(child, schema: itemSchema, depth: depth + 1, path: path + "[\(index)]", report: report)
                }
            }
        }
        if let string = value.string {
            try bounded(Double(string.unicodeScalars.count), minimum: rules["minLength"]?.number,
                        maximum: rules["maxLength"]?.number)
            if let pattern = rules["pattern"]?.string {
                guard string.range(of: pattern, options: .regularExpression) != nil else {
                    throw VisualFaceAssessmentFailure.invalidOutput
                }
            }
            guard !string.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
                    || $0.properties.generalCategory == .surrogate
            }) else { throw VisualFaceAssessmentFailure.invalidOutput }
        }
        if let number = value.number {
            try bounded(number, minimum: rules["minimum"]?.number, maximum: rules["maximum"]?.number)
        }
    }
    private static func bounded(_ value: Double, minimum: Double?, maximum: Double?) throws {
        guard value.isFinite, minimum.map({ value >= $0 }) ?? true,
              maximum.map({ value <= $0 }) ?? true else { throw VisualFaceAssessmentFailure.invalidOutput }
    }
}
