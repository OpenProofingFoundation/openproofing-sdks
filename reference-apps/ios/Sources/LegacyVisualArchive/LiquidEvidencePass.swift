import Foundation

public enum LiquidEvidencePass: String, Codable, CaseIterable, Sendable {
    case quality, comparison, age, presentation
    case sensorConsistency = "sensor_consistency"
}

/// Documentary context, distinct from the model's apparent-age estimate.
public struct VisualDocumentContext: Sendable {
    public let birthDateYYMMDD: String
    public let captureDate: Date
    public var possibleCurrentAges: [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard birthDateYYMMDD.count == 6,
              let year = Int(birthDateYYMMDD.prefix(2)),
              let month = Int(birthDateYYMMDD.dropFirst(2).prefix(2)),
              let day = Int(birthDateYYMMDD.suffix(2)) else { return [] }
        let century = calendar.component(.year, from: captureDate) / 100 * 100
        return [century - 200, century - 100, century].compactMap { base in
            let components = DateComponents(year: base + year, month: month, day: day)
            guard let date = calendar.date(from: components), date <= captureDate,
                  calendar.component(.year, from: date) == components.year,
                  calendar.component(.month, from: date) == components.month,
                  calendar.component(.day, from: date) == components.day,
                  let age = calendar.dateComponents([.year], from: date, to: captureDate).year,
                  (0...130).contains(age) else { return nil }
            return age
        }
    }
    public let documentIssueDate: String?
    public init(birthDateYYMMDD: String, captureDate: Date, documentIssueDate: String?) {
        self.birthDateYYMMDD = birthDateYYMMDD; self.captureDate = captureDate
        self.documentIssueDate = documentIssueDate
    }
    func json() throws -> ReviewJSON {
        guard birthDateYYMMDD.utf8.count == 6, birthDateYYMMDD.utf8.allSatisfy({ (48...57).contains($0) }),
              captureDate.timeIntervalSince1970.isFinite, (0..<253402300800).contains(captureDate.timeIntervalSince1970),
              !possibleCurrentAges.isEmpty, possibleCurrentAges.count <= 2, Set(possibleCurrentAges).count == possibleCurrentAges.count,
              possibleCurrentAges.allSatisfy({ (0...130).contains($0) }),
              documentIssueDate.map({ $0.utf8.count <= 40 }) ?? true else { throw VisualFaceAssessmentFailure.sourceMismatch }
        return .object(["birthDateYYMMDD": .string(birthDateYYMMDD), "captureDate": .string(captureDate.ISO8601Format()),
            "possibleCurrentAges": .array(possibleCurrentAges.map { .number(Double($0)) }),
            "documentIssueDate": documentIssueDate.map(ReviewJSON.string) ?? .null,
            "portraitDate": .null])
    }
}

public struct VisualWorkflowContext: Sendable {
    public struct Window: Sendable {
        public let action: String
        public let summary: CaptureMeasurements.Motion.Summary
        public init(action: String, summary: CaptureMeasurements.Motion.Summary) { self.action = action; self.summary = summary }
    }
    public let sourceSHA256: String
    public let eventCount: Int
    public let motionSampleCount: Int
    public let recordedMotionSeconds: Double
    public let gapSeconds: Double
    public let interactions: [String: Int]
    public let selectedWindows: [Window]
    public let locationStatus: String
    public init(sourceSHA256: String, eventCount: Int, motionSampleCount: Int, recordedMotionSeconds: Double,
                gapSeconds: Double, interactions: [String: Int], selectedWindows: [Window], locationStatus: String) {
        self.sourceSHA256 = sourceSHA256; self.eventCount = eventCount; self.motionSampleCount = motionSampleCount
        self.recordedMotionSeconds = recordedMotionSeconds; self.gapSeconds = gapSeconds
        self.interactions = interactions; self.selectedWindows = selectedWindows; self.locationStatus = locationStatus
    }
    func json() throws -> ReviewJSON {
        guard ReviewJSON.isDigest(sourceSHA256), (0...100000).contains(eventCount), motionSampleCount >= 0,
              motionSampleCount <= 30000000, recordedMotionSeconds.isFinite, recordedMotionSeconds >= 0,
              gapSeconds.isFinite, gapSeconds >= 0, interactions.count <= 64,
              interactions.allSatisfy({ ReviewJSON.isIdentifier($0.key) && (0...100000).contains($0.value) }),
              selectedWindows.count <= 6,
              ["available", "stale", "denied", "restricted", "notRequested", "unavailable"].contains(locationStatus) else {
            throw VisualFaceAssessmentFailure.sourceMismatch
        }
        let windows = try selectedWindows.map { window -> ReviewJSON in
            let s = window.summary
            let numbers = [s.durationSeconds, s.statistics.accelerationRMSg, s.statistics.rotationRMSRadPerSecond,
                           s.statistics.tremorBandRatio, s.statistics.approachRMSg, s.statistics.settleRatio,
                           s.gravity.dominance, s.gravity.driftRadians, s.magnetic.deltaMicrotesla]
            guard ReviewJSON.isIdentifier(window.action), (1...300).contains(s.sampleCount),
                  numbers.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }),
                  ReviewJSON.isDigest(s.rawWindowSHA256) else { throw VisualFaceAssessmentFailure.sourceMismatch }
            return .object(["action": .string(window.action), "summary": .object([
                "sampleCount": .number(Double(s.sampleCount)), "durationSeconds": .number(s.durationSeconds),
                "accelerationRMSg": s.statistics.accelerationRMSg.map(ReviewJSON.number) ?? .null,
                "rotationRMSRadPerSecond": s.statistics.rotationRMSRadPerSecond.map(ReviewJSON.number) ?? .null,
                "tremorBandRatio": s.statistics.tremorBandRatio.map(ReviewJSON.number) ?? .null,
                "approachRMSg": s.statistics.approachRMSg.map(ReviewJSON.number) ?? .null,
                "settleRatio": s.statistics.settleRatio.map(ReviewJSON.number) ?? .null,
                "gravityDominantAxis": s.gravity.dominantAxis.map { .string($0.rawValue) } ?? .null,
                "gravityDominance": s.gravity.dominance.map(ReviewJSON.number) ?? .null,
                "gravityDriftRadians": s.gravity.driftRadians.map(ReviewJSON.number) ?? .null,
                "magneticDeltaMicrotesla": s.magnetic.deltaMicrotesla.map(ReviewJSON.number) ?? .null,
                "magnetometerCalibrated": .bool(s.magnetic.calibrated), "rawWindowSHA256": .string(s.rawWindowSHA256)
            ])])
        }
        return .object(["sourceSHA256": .string(sourceSHA256), "eventCount": .number(Double(eventCount)),
            "motionSampleCount": .number(Double(motionSampleCount)), "recordedMotionSeconds": .number(recordedMotionSeconds),
            "gapSeconds": .number(gapSeconds), "interactions": .object(interactions.mapValues { .number(Double($0)) }),
            "selectedWindows": .array(windows), "locationStatus": .string(locationStatus)])
    }
}

public struct LiquidPassRequest: Sendable {
    public let reference: Data
    public let referenceSHA256: String
    public let selfie: Data
    public let selfieSHA256: String
    public let measurements: CaptureMeasurements?
    public let aura: AuraContext?
    public let document: VisualDocumentContext?
    public let workflow: VisualWorkflowContext?
    public let workflowSnapshotJSON: Data?
    public init(reference: Data, referenceSHA256: String, selfie: Data, selfieSHA256: String,
                measurements: CaptureMeasurements?, aura: AuraContext?, document: VisualDocumentContext?, workflow: VisualWorkflowContext?,
                workflowSnapshotJSON: Data? = nil) {
        self.reference = reference; self.referenceSHA256 = referenceSHA256; self.selfie = selfie; self.selfieSHA256 = selfieSHA256
        self.measurements = measurements; self.aura = aura; self.document = document; self.workflow = workflow
        self.workflowSnapshotJSON = workflowSnapshotJSON
    }
}

public struct LiquidPassReport: Codable, Sendable {
    public struct Indicator: Codable, Sendable {
        public let kind: String
        public let status: String
        public let evidence: String
    }
    public let summary: String
    public let observations: [String]
    public let limitations: [String]
    public let issues: [String]?
    public let referenceAgeRange: [Int]?
    public let selfieAgeRange: [Int]?
    public let auraRelationship: String?
    public let indicators: [Indicator]?

    static func parse(_ data: Data, schema: ReviewJSON, auraAvailable: Bool, depthAvailable: Bool,
                      motionAvailable: Bool, blinkAvailable: Bool = false, interactionsAvailable: Bool = false) throws -> Self {
        let json = try ReviewJSON.parse(data, maximumBytes: LiquidPassProfile.maximumOutputBytes)
        guard !LiquidPassProfile.rejectedOutputSHA256.contains(LiquidPromptContract.digest(try json.encoded())) else {
            throw VisualFaceAssessmentFailure.invalidOutput
        }
        try ReviewSchema.validate(json, schema: schema)
        let value = try JSONDecoder().decode(Self.self, from: data)
        for interval in [value.referenceAgeRange, value.selfieAgeRange].compactMap({ $0 }) {
            guard interval.count == 2, interval[0] <= interval[1] else { throw VisualFaceAssessmentFailure.invalidOutput }
        }
        if !auraAvailable, let relationship = value.auraRelationship, relationship != "not_assessable" {
            throw VisualFaceAssessmentFailure.invalidOutput
        }
        if let indicators = value.indicators {
            guard Set(indicators.map(\.kind)).count == indicators.count else { throw VisualFaceAssessmentFailure.invalidOutput }
            for indicator in indicators where indicator.status != "uncertain" {
                if indicator.kind == "depth_consistency", !depthAvailable { throw VisualFaceAssessmentFailure.invalidOutput }
                if ["device_handling", "motion_coverage"].contains(indicator.kind), !motionAvailable { throw VisualFaceAssessmentFailure.invalidOutput }
                if indicator.kind == "blink_consistency", !blinkAvailable { throw VisualFaceAssessmentFailure.invalidOutput }
                if indicator.kind == "interaction_consistency", !interactionsAvailable { throw VisualFaceAssessmentFailure.invalidOutput }
            }
        }
        return value
    }
}

/// Stored before inference so the exact request is inspectable even if the process is interrupted.
public struct LiquidPassDescriptor: Codable, Sendable {
    public let task: LiquidEvidencePass
    public let profileID: String
    public let artifactSHA256: String
    public let promptContractSHA256: String
    public let contextSHA256: String
    public let promptSHA256: String
    public let schemaSHA256: String
    public let contextJSON: Data
    public var modelInputJSON: Data? = nil
    public var modelInputSHA256: String? = nil
    /// Re-derive evidence without loading model or contract files. The host supplies committed source records.
    public func validateEvidence(request: LiquidPassRequest) throws {
        guard profileID == LiquidPassProfile.id, artifactSHA256 == LiquidProfile.weightsSHA256,
              promptContractSHA256 == LiquidPassProfile.sha256,
              request.reference.count <= LiquidProfile.maximumEncodedBytes,
              request.selfie.count <= LiquidProfile.maximumEncodedBytes,
              LiquidPromptContract.digest(request.reference) == request.referenceSHA256,
              LiquidPromptContract.digest(request.selfie) == request.selfieSHA256,
              let modelInputJSON, let modelInputSHA256 else { throw VisualFaceAssessmentFailure.sourceMismatch }
        let expected = try LiquidPassContract.evidence(pass: task, request: request)
        guard contextJSON == expected.context, contextSHA256 == LiquidPromptContract.digest(expected.context),
              modelInputJSON == expected.modelInput, modelInputSHA256 == LiquidPromptContract.digest(expected.modelInput) else {
            throw VisualFaceAssessmentFailure.sourceMismatch
        }
    }
    private enum CodingKeys: String, CodingKey {
        case task = "pass"
        case profileID, artifactSHA256, promptContractSHA256, contextSHA256, promptSHA256, schemaSHA256, contextJSON
        case modelInputJSON, modelInputSHA256
    }
}

public struct LiquidPassResult: Codable, Sendable {
    public let task: LiquidEvidencePass
    public let profileID: String
    public let artifactSHA256: String
    public let promptContractSHA256: String
    public let referenceSHA256: String
    public let selfieSHA256: String
    public let contextSHA256: String
    public let promptSHA256: String
    public let schemaSHA256: String
    public let outputJSON: Data
    public let report: LiquidPassReport
    public let durationMilliseconds: Double
    public let promptTokens: Int
    public let generatedTokens: Int
    public let peakMemoryBytes: Int
    public var metrics: LiquidRuntimeMetrics? = nil
    private enum CodingKeys: String, CodingKey {
        case task = "pass"
        case profileID, artifactSHA256, promptContractSHA256, referenceSHA256, selfieSHA256, contextSHA256
        case promptSHA256, schemaSHA256, outputJSON, report, durationMilliseconds, promptTokens, generatedTokens, peakMemoryBytes, metrics
    }
}

public struct LiquidPassFailure: Error, Codable, Sendable {
    public enum Reason: String, Codable, Sendable { case tokenLimit, deadline, invalidOutput, resourceLimit, engine, cancelled }
    public let reason: Reason
    public let rawOutput: String
    public let promptTokens: Int
    public let generatedTokens: Int
    public var metrics: LiquidRuntimeMetrics? = nil
    public init(reason: Reason, rawOutput: String = "", promptTokens: Int = 0, generatedTokens: Int = 0,
                metrics: LiquidRuntimeMetrics? = nil) {
        self.reason = reason; self.rawOutput = String(rawOutput.prefix(8192))
        self.promptTokens = promptTokens; self.generatedTokens = generatedTokens; self.metrics = metrics
    }
}

/// Phase timings and allocator observations, including unsuccessful generation.
public struct LiquidRuntimeMetrics: Codable, Sendable {
    public enum AllocatorPeakScope: String, Codable, Sendable { case processLifetime = "process_lifetime" }
    public let allocatorPeakScope: AllocatorPeakScope
    public var modelSetupMilliseconds: Double
    public var imagePreparationMilliseconds: Double
    public var grammarPreparationMilliseconds: Double
    public var prefillMilliseconds: Double
    public var generationMilliseconds: Double
    public var cleanupMilliseconds: Double
    public var activeMemoryBytes: Int
    public var cacheMemoryBytes: Int
    public var peakMemoryBytes: Int
    public init(modelSetupMilliseconds: Double = .zero, imagePreparationMilliseconds: Double = .zero,
                grammarPreparationMilliseconds: Double = .zero, prefillMilliseconds: Double = .zero,
                generationMilliseconds: Double = .zero, cleanupMilliseconds: Double = .zero,
                activeMemoryBytes: Int = 0, cacheMemoryBytes: Int = 0, peakMemoryBytes: Int = 0,
                allocatorPeakScope: AllocatorPeakScope = .processLifetime) {
        self.allocatorPeakScope = allocatorPeakScope
        self.modelSetupMilliseconds = modelSetupMilliseconds; self.imagePreparationMilliseconds = imagePreparationMilliseconds
        self.grammarPreparationMilliseconds = grammarPreparationMilliseconds; self.prefillMilliseconds = prefillMilliseconds
        self.generationMilliseconds = generationMilliseconds; self.cleanupMilliseconds = cleanupMilliseconds
        self.activeMemoryBytes = activeMemoryBytes; self.cacheMemoryBytes = cacheMemoryBytes; self.peakMemoryBytes = peakMemoryBytes
    }
    private enum CodingKeys: String, CodingKey {
        case allocatorPeakScope, modelSetupMilliseconds, imagePreparationMilliseconds, grammarPreparationMilliseconds
        case prefillMilliseconds, generationMilliseconds, cleanupMilliseconds, activeMemoryBytes, cacheMemoryBytes, peakMemoryBytes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        allocatorPeakScope = try values.decodeIfPresent(AllocatorPeakScope.self, forKey: .allocatorPeakScope) ?? .processLifetime
        modelSetupMilliseconds = try values.decode(Double.self, forKey: .modelSetupMilliseconds)
        imagePreparationMilliseconds = try values.decode(Double.self, forKey: .imagePreparationMilliseconds)
        grammarPreparationMilliseconds = try values.decode(Double.self, forKey: .grammarPreparationMilliseconds)
        prefillMilliseconds = try values.decode(Double.self, forKey: .prefillMilliseconds)
        generationMilliseconds = try values.decode(Double.self, forKey: .generationMilliseconds)
        cleanupMilliseconds = try values.decode(Double.self, forKey: .cleanupMilliseconds)
        activeMemoryBytes = try values.decode(Int.self, forKey: .activeMemoryBytes)
        cacheMemoryBytes = try values.decode(Int.self, forKey: .cacheMemoryBytes)
        peakMemoryBytes = try values.decode(Int.self, forKey: .peakMemoryBytes)
    }
}

/// Frozen v4 archive bounds and contamination fingerprint.
enum LiquidPassProfile {
    static let id = "lfm25-vl16b-affine4-g64-mlx-discrete-review-v4"
    static let sha256 = "d0e596b10971316b7525188f0919cbf073a0ff7b21eea306c8fecd4f19f6b35f"
    static let maximumOutputBytes = 8192
    static let maximumContextBytes = 32768
    static let maximumModelInputBytes = 16384
    static let rejectedOutputSHA256: Set<String> = ["927b6b5acec2a691fd809f74281a4e4748eb98d8f1e1357e5953512d5c9c9381"]
}

struct LiquidPassContract: Sendable {
    /// Reconstruct historical evidence for durable-store readback; no file or model access.
    static func evidence(pass: LiquidEvidencePass, request: LiquidPassRequest) throws -> (context: Data, modelInput: Data) {
        guard ReviewJSON.isDigest(request.referenceSHA256), ReviewJSON.isDigest(request.selfieSHA256) else {
            throw VisualFaceAssessmentFailure.sourceMismatch
        }
        try request.measurements?.validate(selfieSHA256: request.selfieSHA256)
        try request.aura?.validate(referenceSHA256: request.referenceSHA256, selfieSHA256: request.selfieSHA256)
        let measurements = request.measurements?.json() ?? .null
        let aura = request.aura?.json() ?? .null
        let document = try request.document?.json() ?? .null
        let workflow = try request.workflow?.json() ?? .null
        let snapshot = try Self.snapshot(request)
        let full = ReviewJSON.object(["schemaVersion": .number(2), "pass": .string(pass.rawValue),
            "referenceSHA256": .string(request.referenceSHA256), "selfieSHA256": .string(request.selfieSHA256),
            "captureMode": .string("still"), "measurements": measurements, "aura": aura,
            "document": document, "workflow": workflow, "workflowSnapshot": snapshot])
        let input = try full.encoded()
        guard input.count <= LiquidPassProfile.maximumContextBytes else { throw VisualFaceAssessmentFailure.resourceLimit }
        var model: [String: ReviewJSON] = ["task": .string(pass.rawValue), "captureMode": .string("still")]
        switch pass {
        case .quality:
            model["images"] = .array([.string("reference"), .string("selfie")])
            model["selfieQuality"] = measurements.object?["quality"] ?? .null
        case .comparison:
            model["images"] = .array([.string("reference"), .string("selfie")])
            model["aura"] = aura
        case .age:
            model["images"] = .array([.string("reference"), .string("selfie")])
            model["document"] = document
        case .presentation:
            model["images"] = .array([.string("selfie")])
        case .sensorConsistency:
            model["measurements"] = measurements
            model["workflow"] = workflow
        }
        let projection = try Self.compact(.object(model)).encoded()
        guard projection.count <= LiquidPassProfile.maximumModelInputBytes else { throw VisualFaceAssessmentFailure.resourceLimit }
        return (input, projection)
    }

    /// Validate the committed manifest; raw events remain in the host's protected archive.
    private static func snapshot(_ request: LiquidPassRequest) throws -> ReviewJSON {
        guard let data = request.workflowSnapshotJSON else { return .null }
        let value = try ReviewJSON.parse(data, maximumBytes: 4096)
        guard let object = value.object,
              Set(object.keys).isSubset(of: ["schemaVersion", "operationID", "workflowID", "throughEventID", "lastSequence", "archiveSHA256", "referenceSHA256", "selfieSHA256", "recordedAt"]),
              object["schemaVersion"]?.number == 1,
              let operationID = object["operationID"]?.string, UUID(uuidString: operationID) != nil,
              object["referenceSHA256"]?.string == request.referenceSHA256,
              object["selfieSHA256"]?.string == request.selfieSHA256,
              let sequence = object["lastSequence"]?.number, sequence >= 0, sequence <= 100000, sequence.rounded(.towardZero) == sequence,
              let recordedAt = object["recordedAt"]?.string, validDate(recordedAt) else {
            throw VisualFaceAssessmentFailure.sourceMismatch
        }
        if let workflowID = object["workflowID"]?.string {
            guard UUID(uuidString: workflowID) != nil, sequence > 0,
                  let eventID = object["throughEventID"]?.string, UUID(uuidString: eventID) != nil,
                  let digest = object["archiveSHA256"]?.string, ReviewJSON.isDigest(digest),
                  Set(object.keys) == ["schemaVersion", "operationID", "workflowID", "throughEventID", "lastSequence", "archiveSHA256", "referenceSHA256", "selfieSHA256", "recordedAt"],
                  request.workflow?.sourceSHA256 == digest else { throw VisualFaceAssessmentFailure.sourceMismatch }
        } else {
            guard Set(object.keys) == ["schemaVersion", "operationID", "lastSequence", "referenceSHA256", "selfieSHA256", "recordedAt"],
                  sequence == 0, request.workflow == nil else {
                throw VisualFaceAssessmentFailure.sourceMismatch
            }
        }
        return value
    }
    private static func validDate(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }
    /// Reduction is model-only. Evidence hashes and full floating-point values remain in contextData.
    private static func compact(_ value: ReviewJSON) -> ReviewJSON {
        switch value {
        case .number(let number):
            let scaled = number * 10000
            return .number(scaled.isFinite ? scaled.rounded() / 10000 : number)
        case .array(let values): return .array(values.map(compact))
        case .object(let object):
            let omitted: Set<String> = ["binding", "policyId", "frameTimestampSeconds", "imageTimestampSeconds", "depthTimestampSeconds", "completedAtSeconds"]
            return .object(object.filter { !$0.key.hasSuffix("SHA256") && !omitted.contains($0.key) }.mapValues(compact))
        default: return value
        }
    }
}

