import Foundation

/// Read-only presentation of already stored model output. No inference or orchestration.
enum LegacyLiquidArchive {
    static let currentProfileID = "lfm25-vl16b-affine4-g64-mlx-discrete-review-v4"

    static func isHistorical(_ value: FaceVisualAssessmentCompletion) -> Bool { true }

    static func presentation(capture: SavedFaceCapture, aura: SavedFaceStage, events: [SavedLiquidPass], settled: Bool = true,
                             unavailableReason: SavedComparisonSnapshot.UnavailableReason? = nil) -> FaceVisualAssessmentCompletion {
        let latest = events.last { $0.auraID == aura.id }?.descriptor
        let events = events.filter { $0.descriptor.profileID == latest?.profileID && $0.descriptor.promptContractSHA256 == latest?.promptContractSHA256 }
        let tasks: [LiquidEvidencePass] = latest?.profileID == "lfm25-vl16b-affine4-g64-mlx-discrete-review-v3"
            ? [.quality, .comparison, .presentation] : LiquidEvidencePass.allCases
        var sections: [FaceVisualReportSection] = []
        var summaries: [String] = []
        var duration = 0.0
        for pass in tasks {
            let event = events.last { $0.auraID == aura.id && $0.descriptor.task == pass }
            var fields = [FaceTelemetryField(key: "report.pass.status", value: .code("report.pass.\(event?.status.rawValue ?? "not_started")"))]
            if let event {
                fields += [.init(key: "report.pass.profile", value: .text(event.descriptor.profileID)),
                           .init(key: "report.pass.inputSHA", value: .text(event.descriptor.contextSHA256))]
            }
            if let result = event?.result {
                duration += result.durationMilliseconds
                summaries.append(result.report.summary)
                fields += result.report.observations.map { .init(key: "report.observation", value: .text($0)) }
                fields += result.report.limitations.map { .init(key: "report.limitation", value: .text($0)) }
                fields += (result.report.issues ?? []).map { .init(key: "report.qualityIssue", value: .text($0)) }
                if let range = result.report.referenceAgeRange {
                    fields += [.init(key: "report.pass.referenceAgeMin", value: .integer(range[0])), .init(key: "report.pass.referenceAgeMax", value: .integer(range[1]))]
                }
                if let range = result.report.selfieAgeRange {
                    fields += [.init(key: "report.pass.selfieAgeMin", value: .integer(range[0])), .init(key: "report.pass.selfieAgeMax", value: .integer(range[1]))]
                }
                if let relationship = result.report.auraRelationship { fields.append(.init(key: "report.relationship", value: .code("report.aura.\(relationship)"))) }
                fields += [.init(key: "report.pass.promptTokens", value: .integer(result.promptTokens)),
                           .init(key: "report.pass.generatedTokens", value: .integer(result.generatedTokens)),
                           .init(key: "report.pass.peakMemoryBytes", value: .integer(result.peakMemoryBytes)),
                           .init(key: "report.pass.duration", value: .number(result.durationMilliseconds))]
                for indicator in result.report.indicators ?? [] {
                    fields.append(.init(key: "report.indicator.\(indicator.kind)", value: .code("report.status.\(indicator.status)")))
                    fields.append(.init(key: "report.evidence", value: .text(indicator.evidence)))
                }
            }
            if let metrics = event?.result?.metrics ?? event?.failure?.metrics {
                fields += [.init(key: "report.pass.modelSetup", value: .number(metrics.modelSetupMilliseconds)),
                           .init(key: "report.pass.imagePreparation", value: .number(metrics.imagePreparationMilliseconds)),
                           .init(key: "report.pass.grammarPreparation", value: .number(metrics.grammarPreparationMilliseconds)),
                           .init(key: "report.pass.prefill", value: .number(metrics.prefillMilliseconds)),
                           .init(key: "report.pass.generation", value: .number(metrics.generationMilliseconds)),
                           .init(key: "report.pass.cleanup", value: .number(metrics.cleanupMilliseconds)),
                           .init(key: "report.pass.activeMemory", value: .integer(metrics.activeMemoryBytes)),
                           .init(key: "report.pass.cacheMemory", value: .integer(metrics.cacheMemoryBytes))]
            }
            if let failure = event?.failure {
                duration += event?.durationMilliseconds ?? 0
                fields += [.init(key: "report.pass.duration", value: .number(event?.durationMilliseconds ?? 0)),
                           .init(key: "report.pass.failure", value: .text(event?.failureCode ?? failure.reason.rawValue)),
                           .init(key: "report.pass.promptTokens", value: .integer(failure.promptTokens)),
                           .init(key: "report.pass.generatedTokens", value: .integer(failure.generatedTokens))]
            }
            sections.append(.init(titleKey: "report.pass.\(pass.rawValue)", fields: fields))
        }
        if let passport = capture.input.passport {
            let document = VisualDocumentContext(birthDateYYMMDD: passport.nfc.birthDateYYMMDD,
                captureDate: capture.recordedAt, documentIssueDate: passport.nfc.dateOfIssue)
            var fields = [FaceTelemetryField(key: "report.pass.claimedDOB", value: .text(document.birthDateYYMMDD))]
            fields += document.possibleCurrentAges.map { .init(key: "report.pass.claimedAge", value: .integer($0)) }
            sections.append(.init(titleKey: "report.age.title", fields: fields))
        }
        if let unavailableReason {
            sections.append(.init(titleKey: "report.workflow.title", fields: [
                .init(key: "report.workflow.status", value: .code("report.workflow.unavailable.\(unavailableReason.rawValue)"))]))
        }
        let latestTasks = tasks.compactMap { task in events.last { $0.auraID == aura.id && $0.descriptor.task == task } }
        let completed = latestTasks.filter { $0.status == .completed }.count
        let aggregate: FaceVisualAggregateStatus
        if !settled { aggregate = .processing }
        else if latestTasks.contains(where: { $0.failure?.reason == .cancelled }) { aggregate = .cancelled }
        else if completed == tasks.count { aggregate = .completed }
        else if completed > 0 { aggregate = .partial }
        else { aggregate = .failed }
        sections.insert(.init(titleKey: "report.aggregate.title", fields: [
            .init(key: "report.pass.status", value: .code("report.aggregate.\(aggregate.rawValue)")),
            .init(key: "report.aggregate.completedCount", value: .integer(completed)),
            .init(key: "report.aggregate.total", value: .integer(tasks.count))]), at: 0)
        return .init(operationID: capture.input.operationID, referenceSHA256: capture.input.referenceSHA256,
            selfieSHA256: capture.input.selfieSHA256, consistency: nil, issues: [], durationMilliseconds: duration,
            report: .init(summary: summaries.joined(separator: "\n"), sections: sections),
            aggregateStatus: aggregate, completedTaskCount: completed, totalTaskCount: tasks.count)
    }
}

/// Historical committed-evidence reconstruction for storage validation only.
enum LiquidPassEvidence {
    static func request(capture: SavedFaceCapture, aura: SavedFaceStage, snapshot: SavedComparisonSnapshot) throws -> LiquidPassRequest {
        try capture.validate(); try aura.validate(for: capture); try snapshot.validate(capture: capture)
        let input = FaceVisualAssessmentInput(source: capture.input, aura: aura.aura)
        let candidateDocument = capture.input.passport.map {
            VisualDocumentContext(birthDateYYMMDD: $0.nfc.birthDateYYMMDD,
                captureDate: capture.recordedAt, documentIssueDate: $0.nfc.dateOfIssue)
        }
        let document = candidateDocument.flatMap { $0.possibleCurrentAges.isEmpty ? nil : $0 }
        let workflow = try snapshot.archive.map(Self.workflow)
        return LiquidPassRequest(reference: capture.input.reference, referenceSHA256: capture.input.referenceSHA256,
            selfie: capture.input.selfie, selfieSHA256: capture.input.selfieSHA256,
            measurements: try FaceComparisonHost.captureMeasurements(capture.input.captureContext, selfieSHA256: capture.input.selfieSHA256),
            aura: try FaceComparisonHost.auraContext(input), document: document, workflow: workflow,
            workflowSnapshotJSON: try snapshot.manifest())
    }

    private static func workflow(_ archive: WorkflowEvidenceArchive) throws -> VisualWorkflowContext {
        let motion = archive.events.compactMap { event -> (String, SavedWorkflowMotion)? in
            event.motion.map { (event.action, $0) }
        }
        let indices = Set((0..<min(6, motion.count)).map { index in index * max(0, motion.count - 1) / max(1, min(6, motion.count) - 1) }).sorted()
        let selected = indices.map { index -> VisualWorkflowContext.Window in
            let event = motion[index]
            let s = event.1.summary
            let axis = s.gravityDominantAxis.flatMap(CaptureMeasurements.Motion.Gravity.Axis.init(rawValue:))
            return .init(action: event.0, summary: .init(sampleCount: s.sampleCount, durationSeconds: s.durationSeconds,
                statistics: .init(accelerationRMSg: s.accelerationRMSg, rotationRMSRadPerSecond: s.rotationRMSRadPerSecond,
                    tremorBandRatio: s.tremorBandRatio, approachRMSg: s.approachRMSg, settleRatio: s.settleRatio),
                gravity: .init(dominantAxis: axis, dominance: s.gravityDominance, driftRadians: s.gravityDriftRadians),
                magnetic: .init(deltaMicrotesla: s.magneticDeltaMicrotesla, calibrated: s.magnetometerCalibrated), rawWindowSHA256: s.rawWindowSHA256))
        }
        var actions: [String: Int] = [:]
        for event in archive.events where event.action != "sensor.window" { actions[event.action, default: 0] += 1 }
        let location = archive.events.last?.location
        let status: String
        if let location, location.usable { status = "available" }
        else if location?.fix != nil { status = "stale" }
        else if location?.permission == .authorized { status = "unavailable" }
        else { status = location?.permission.rawValue ?? "unavailable" }
        return VisualWorkflowContext(sourceSHA256: try FaceComparisonHost.sourceDigest(archive), eventCount: archive.events.count,
            motionSampleCount: motion.reduce(0) { $0 + $1.1.samples.count },
            recordedMotionSeconds: motion.reduce(0) { $0 + $1.1.summary.durationSeconds },
            gapSeconds: archive.events.reduce(0) { $0 + ($1.gapBeforeSeconds ?? 0) },
            interactions: actions, selectedWindows: selected, locationStatus: status)
    }
}
