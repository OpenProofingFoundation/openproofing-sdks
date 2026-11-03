import Foundation

/// Append-only attempt events: pending is committed before inference; terminal events never replace it.
struct SavedLiquidPass: Codable, Sendable {
    enum Status: String, Codable, Sendable { case pending, completed, failed }
    let version: Int
    let id: UUID
    let attemptID: UUID
    let operationID: UUID
    let auraID: UUID
    let recordedAt: Date
    let status: Status
    let durationMilliseconds: Double
    let descriptor: LiquidPassDescriptor
    let result: LiquidPassResult?
    let failure: LiquidPassFailure?
    let failureCode: String?

    init(operationID: UUID, auraID: UUID, descriptor: LiquidPassDescriptor) {
        version = 1; id = UUID(); attemptID = UUID(); self.operationID = operationID; self.auraID = auraID
        recordedAt = Date(); status = .pending; durationMilliseconds = 0; self.descriptor = descriptor
        result = nil; failure = nil; failureCode = nil
    }
    private init(start: SavedLiquidPass, result: LiquidPassResult?, failure: LiquidPassFailure?, code: String?, duration: Double) {
        version = 1; id = UUID(); attemptID = start.attemptID; operationID = start.operationID; auraID = start.auraID
        recordedAt = Date(); status = result == nil ? .failed : .completed; descriptor = start.descriptor
        self.result = result; self.failure = failure; failureCode = code; durationMilliseconds = duration
    }
    func completed(_ result: LiquidPassResult) -> Self { Self(start: self, result: result, failure: nil, code: nil, duration: result.durationMilliseconds) }
    func failed(_ failure: LiquidPassFailure, code: String, durationMilliseconds: Double = 0) -> Self {
        Self(start: self, result: nil, failure: failure, code: code, duration: durationMilliseconds)
    }

    func validate(capture: SavedFaceCapture, aura: SavedFaceStage) throws {
        guard version == 1, SavedFaceCapture.validDate(recordedAt), durationMilliseconds.isFinite, durationMilliseconds >= 0, capture.input.operationID == operationID,
              aura.id == auraID, aura.operationID == operationID, aura.engine == .aura,
              descriptor.contextJSON.count <= 32768,
              SavedPassportCapture.digest(descriptor.contextJSON) == descriptor.contextSHA256,
              [descriptor.artifactSHA256, descriptor.promptContractSHA256, descriptor.contextSHA256,
               descriptor.promptSHA256, descriptor.schemaSHA256].allSatisfy({ $0.utf8.count == 64 && $0.allSatisfy(\.isHexDigit) }),
              let context = try JSONSerialization.jsonObject(with: descriptor.contextJSON) as? [String: Any],
              context["referenceSHA256"] as? String == capture.input.referenceSHA256,
              context["selfieSHA256"] as? String == capture.input.selfieSHA256,
              context["pass"] as? String == descriptor.task.rawValue else { throw FaceWorkflowStorageFailure.invalidRecord }
        if let modelInput = descriptor.modelInputJSON {
            guard modelInput.count <= 32768, descriptor.modelInputSHA256 == SavedPassportCapture.digest(modelInput) else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
        } else if descriptor.modelInputSHA256 != nil { throw FaceWorkflowStorageFailure.invalidRecord }
        if let metrics = result?.metrics ?? failure?.metrics {
            guard [metrics.modelSetupMilliseconds, metrics.imagePreparationMilliseconds,
                   metrics.grammarPreparationMilliseconds, metrics.prefillMilliseconds, metrics.generationMilliseconds,
                   metrics.cleanupMilliseconds].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  metrics.activeMemoryBytes >= 0, metrics.cacheMemoryBytes >= 0, metrics.peakMemoryBytes >= 0 else {
                throw FaceWorkflowStorageFailure.invalidRecord
            }
        }
        switch status {
        case .pending:
            guard result == nil, failure == nil, failureCode == nil else { throw FaceWorkflowStorageFailure.invalidRecord }
        case .completed:
            guard let result, failure == nil, failureCode == nil,
                  result.task == descriptor.task, result.profileID == descriptor.profileID,
                  result.artifactSHA256 == descriptor.artifactSHA256, result.promptContractSHA256 == descriptor.promptContractSHA256,
                  result.contextSHA256 == descriptor.contextSHA256, result.promptSHA256 == descriptor.promptSHA256,
                  result.schemaSHA256 == descriptor.schemaSHA256,
                  result.referenceSHA256 == capture.input.referenceSHA256, result.selfieSHA256 == capture.input.selfieSHA256,
                  result.durationMilliseconds.isFinite, result.durationMilliseconds >= 0,
                  (0...4096).contains(result.promptTokens), (0...384).contains(result.generatedTokens), result.peakMemoryBytes >= 0,
                  !result.outputJSON.isEmpty, result.outputJSON.count <= 8192 else { throw FaceWorkflowStorageFailure.invalidRecord }
            let report = result.report
            func text(_ value: String, maximum: Int) -> Bool {
                !value.isEmpty && value.unicodeScalars.count <= maximum &&
                    !value.unicodeScalars.contains { [.control, .format, .surrogate].contains($0.properties.generalCategory) }
            }
            guard text(report.summary, maximum: 200), report.observations.count <= 3,
                  report.observations.allSatisfy({ text($0, maximum: 160) }), report.limitations.count <= 2,
                  report.limitations.allSatisfy({ text($0, maximum: 120) }),
                  [report.referenceAgeRange, report.selfieAgeRange].compactMap({ $0 }).allSatisfy({
                      $0.count == 2 && (0...130).contains($0[0]) && (0...130).contains($0[1]) && $0[0] <= $0[1]
                  }) else { throw FaceWorkflowStorageFailure.invalidRecord }
            if let indicators = report.indicators {
                guard indicators.count <= 4, Set(indicators.map(\.kind)).count == indicators.count,
                      indicators.allSatisfy({ text($0.evidence, maximum: 160) && ["present", "absent", "uncertain"].contains($0.status) }) else {
                    throw FaceWorkflowStorageFailure.invalidRecord
                }
            }
            var expected: Set<String> = ["summary", "observations", "limitations"]
            switch descriptor.task {
            case .quality: expected.insert("issues")
            case .comparison:
                if descriptor.profileID.hasSuffix("-v3") { expected.formUnion(["referenceAgeRange", "selfieAgeRange", "auraRelationship"]) }
                else { expected.insert("auraRelationship") }
            case .age: expected.formUnion(["referenceAgeRange", "selfieAgeRange"])
            case .presentation, .sensorConsistency: expected.insert("indicators")
            }
            guard let object = try JSONSerialization.jsonObject(with: result.outputJSON) as? [String: Any],
                  Set(object.keys) == expected else { throw FaceWorkflowStorageFailure.invalidRecord }
            let decoded = try JSONDecoder().decode(LiquidPassReport.self, from: result.outputJSON)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard try encoder.encode(decoded) == encoder.encode(report) else { throw FaceWorkflowStorageFailure.invalidRecord }
        case .failed:
            guard result == nil, let failure, failure.rawOutput.utf8.count <= 32768,
                  let failureCode, !failureCode.isEmpty, failureCode.utf8.count <= 128,
                  failure.promptTokens >= 0, failure.generatedTokens >= 0 else { throw FaceWorkflowStorageFailure.invalidRecord }
        }
    }
    func exportObject() throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard var value = try JSONSerialization.jsonObject(with: encoder.encode(self)) as? [String: Any],
              var request = value["descriptor"] as? [String: Any] else { throw FaceWorkflowStorageFailure.invalidRecord }
        request.removeValue(forKey: "contextJSON")
        request["inputContext"] = try JSONSerialization.jsonObject(with: descriptor.contextJSON)
        request.removeValue(forKey: "modelInputJSON")
        if let modelInput = descriptor.modelInputJSON {
            request["modelInput"] = try JSONSerialization.jsonObject(with: modelInput)
        }
        value["descriptor"] = request
        if let result, var output = value["result"] as? [String: Any] {
            output.removeValue(forKey: "outputJSON")
            output["rawOutput"] = String(decoding: result.outputJSON, as: UTF8.self)
            value["result"] = output
        }
        return value
    }

    func matches(_ other: LiquidPassDescriptor) -> Bool {
        descriptor.task == other.task && descriptor.profileID == other.profileID && descriptor.contextSHA256 == other.contextSHA256 &&
            descriptor.promptContractSHA256 == other.promptContractSHA256 && descriptor.promptSHA256 == other.promptSHA256 &&
            descriptor.schemaSHA256 == other.schemaSHA256 && descriptor.artifactSHA256 == other.artifactSHA256 &&
            descriptor.modelInputJSON == other.modelInputJSON && descriptor.modelInputSHA256 == other.modelInputSHA256
    }
}
