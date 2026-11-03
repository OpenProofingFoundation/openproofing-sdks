import Foundation
import CryptoKit
import BiometricCapture
import BiometricInference

/// Resource discovery and SDK adaptation only; processing remains off the UI actor.
@MainActor enum FaceComparisonHost {
    static func makeController(persistence: FaceWorkflowPersistence? = nil,
                               modelURL: URL? = Bundle.main.url(forResource: "AuraFace", withExtension: "onnx")) -> FaceComparisonController {
        let url = modelURL
        let run: @Sendable (FaceComparisonInput, FaceImagePreflightObservation?) async throws -> FaceComparisonCompletion = { input, prepared in
            guard let url else { throw FaceInferenceFailure.modelUnavailable }
            let engine = AuraFaceComparison(modelURL: url)
            let observation: FaceSimilarityObservation
            if let prepared {
                guard prepared.sourceSHA256 == input.selfieSHA256,
                      input.selection?.selectedAlignedSHA256 == prepared.alignedSHA256 else { throw FaceInferenceFailure.sourceMismatch }
                observation = try await engine.compare(reference: input.reference,
                    referenceSHA256: input.referenceSHA256, preparedSelfie: prepared)
            } else {
                observation = try await engine.compare(reference: input.reference,
                    referenceSHA256: input.referenceSHA256, selfie: input.selfie, selfieSHA256: input.selfieSHA256)
            }
            let resultSHA256 = try sourceDigest(AuraSourceRecord(operationID: input.operationID,
                referenceSHA256: observation.referenceSHA256, selfieSHA256: observation.selfieSHA256,
                referenceAlignedSHA256: observation.referenceAlignedSHA256, selfieAlignedSHA256: observation.selfieAlignedSHA256,
                artifactManifestSHA256: observation.artifactManifestSHA256, alignmentRoute: observation.alignmentRoute,
                score: observation.similarity.value, dimensions: observation.similarity.space.dimensions,
                minimumNorm: observation.similarity.space.minimumNorm))
            return FaceComparisonCompletion(operationID: input.operationID,
                referenceSHA256: observation.referenceSHA256, selfieSHA256: observation.selfieSHA256,
                score: observation.similarity.value, telemetry: [
                    .init(key: "telemetry.aura.resultSHA256", value: .text(resultSHA256)),
                    .init(key: "telemetry.aura.referenceAlignedSHA256", value: .text(observation.referenceAlignedSHA256)),
                    .init(key: "telemetry.aura.selfieAlignedSHA256", value: .text(observation.selfieAlignedSHA256)),
                    .init(key: "telemetry.aura.artifactManifestSHA256", value: .text(observation.artifactManifestSHA256)),
                    .init(key: "telemetry.aura.alignmentRoute", value: .text(observation.alignmentRoute)),
                    .init(key: "telemetry.aura.domain", value: .text(observation.similarity.space.domain.rawValue)),
                    .init(key: "telemetry.aura.dimensions", value: .integer(observation.similarity.space.dimensions)),
                    .init(key: "telemetry.aura.minimumNorm", value: .number(observation.similarity.space.minimumNorm)),
                    .init(key: "telemetry.aura.angularDistance", value: .number(observation.similarity.angularDistanceRadians))
                ], resultSHA256: resultSHA256)
        }
        let compare: @Sendable (FaceComparisonInput) async throws -> FaceComparisonCompletion = { try await run($0, nil) }
        if let persistence {
            let pipeline = FaceWorkflowPipeline(persistence: persistence, compare: compare)
            return FaceComparisonController(compare: { try await pipeline.runAura($0) }, persistence: persistence,
                comparePrepared: { input, prepared in
                    try await pipeline.runAura(input, preparedCompare: { try await run($0, prepared) })
                })
        }
        return FaceComparisonController(compare: { input in
            try await FaceInferenceScheduler.shared.run { try await compare(input) }
        }, comparePrepared: { input, prepared in
            try await FaceInferenceScheduler.shared.run { try await run(input, prepared) }
        })
    }

    private struct AuraSourceRecord: Encodable {
        let operationID: UUID
        let referenceSHA256: String
        let selfieSHA256: String
        let referenceAlignedSHA256: String
        let selfieAlignedSHA256: String
        let artifactManifestSHA256: String
        let alignmentRoute: String
        let score: Double
        let dimensions: Int
        let minimumNorm: Double
    }

    nonisolated static func auraContext(_ input: FaceVisualAssessmentInput) throws -> AuraContext? {
        guard let value = input.aura else { return nil }
        guard value.operationID == input.operationID, value.referenceSHA256 == input.referenceSHA256,
              value.selfieSHA256 == input.selfieSHA256, let digest = value.resultSHA256 else {
            throw FaceVisualAssessmentFailure.sourceMismatch
        }
        return AuraContext(cosineSimilarity: value.score,
            interpretation: "Unthresholded cosine similarity; larger values indicate closer embedding direction.",
            policyId: nil, resultSHA256: digest, referenceSHA256: value.referenceSHA256, selfieSHA256: value.selfieSHA256)
    }

    nonisolated static func captureMeasurements(_ context: FaceCaptureContext?, selfieSHA256: String) throws -> CaptureMeasurements? {
        guard let context else { return nil }
        guard context.selfieSHA256 == selfieSHA256 else { throw FaceVisualAssessmentFailure.sourceMismatch }
        let receipt = context.receipt
        let sourceSHA256 = try sourceDigest(receipt)
        let depth: CaptureMeasurements.Depth?
        if let value = receipt.depthEvidence {
            guard let frame = receipt.frameEvidence, value.imageSHA256 == selfieSHA256,
                  value.imageTimestamp == receipt.frameTimestamp, value.orientation == frame.orientation,
                  value.ageAtAdmission == frame.frameAgeAtAdmission + receipt.frameTimestamp - value.depthTimestamp else {
                throw FaceVisualAssessmentFailure.sourceMismatch
            }
            depth = .init(sourceSHA256: try sourceDigest(value),
                timing: .init(imageTimestampSeconds: value.imageTimestamp, depthTimestampSeconds: value.depthTimestamp,
                    ageAtAdmissionSeconds: value.ageAtAdmission),
                map: .init(width: value.mapWidth, height: value.mapHeight, filtered: value.filtered),
                sampleCount: value.measurement.sampleCount, residualRMSMetres: value.measurement.residualRMS)
        } else { depth = nil }
        let motion: CaptureMeasurements.Motion?
        if let value = receipt.motionEvidence {
            guard receipt.motionStatus == .authorized,
                  value.imageSHA256 == selfieSHA256, value.frameTimestampSeconds == receipt.frameTimestamp,
                  value.clockDomain == "core_motion_boot_seconds", value.alignment == "host_uptime_checked",
                  value.summary.ceremony == .faceMatch else { throw FaceVisualAssessmentFailure.sourceMismatch }
            let summary = value.summary
            let axis = summary.gravityDominantAxis.flatMap(CaptureMeasurements.Motion.Gravity.Axis.init(rawValue:))
            guard summary.gravityDominantAxis == nil || axis != nil else { throw FaceVisualAssessmentFailure.sourceMismatch }
            motion = .init(sourceSHA256: try sourceDigest(value), frameTimestampSeconds: value.frameTimestampSeconds,
                windowStartTimestampSeconds: value.windowStartTimestampSeconds, windowEndTimestampSeconds: value.windowEndTimestampSeconds,
                requestedSampleRateHz: value.requestedSampleRateHz,
                summary: .init(sampleCount: summary.sampleCount, durationSeconds: summary.durationSeconds,
                    statistics: .init(accelerationRMSg: summary.accelerationRMSg, rotationRMSRadPerSecond: summary.rotationRMSRadPerSecond,
                        tremorBandRatio: summary.tremorBandRatio, approachRMSg: summary.approachRMSg, settleRatio: summary.settleRatio),
                    gravity: .init(dominantAxis: axis, dominance: summary.gravityDominance, driftRadians: summary.gravityDriftRadians),
                    magnetic: .init(deltaMicrotesla: summary.magneticDeltaMicrotesla, calibrated: summary.magnetometerCalibrated),
                    rawWindowSHA256: summary.rawWindowSHA256))
        } else { motion = nil }
        return CaptureMeasurements(binding: .init(imageSHA256: selfieSHA256, sourceSHA256: sourceSHA256,
            frameTimestampSeconds: receipt.frameTimestamp, clockDomain: "arkit_session_seconds"),
            depth: depth,
            blink: .init(completedAtSeconds: receipt.blinkCompletedAt, ageSeconds: receipt.blinkAge,
                leftEyeClosed: Double(receipt.leftEyeClosed), rightEyeClosed: Double(receipt.rightEyeClosed), eyesOpen: receipt.eyesOpen),
            tracking: .init(consecutiveFrames: receipt.consecutiveTrackedFrames, steadyHoldSeconds: receipt.steadyHoldDuration),
            quality: .init(score: receipt.captureQuality.map(Double.init), revision: receipt.frameEvidence?.qualityRevision,
                insideGuide: receipt.insideGuide, analysisDurationSeconds: receipt.frameEvidence?.analysisDuration,
                frameAgeAtAdmissionSeconds: receipt.frameEvidence?.frameAgeAtAdmission), motion: motion)
    }

    nonisolated static func sourceDigest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(value) else { throw FaceVisualAssessmentFailure.sourceMismatch }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func mapReport(_ report: VisualEvidenceReview) -> FaceVisualReport {
        func text(_ key: String, _ values: [String]) -> [FaceTelemetryField] {
            values.isEmpty ? [.init(key: key, value: .code("telemetry.noneReported"))] : values.map { .init(key: key, value: .text($0)) }
        }
        func image(_ value: VisualEvidenceReview.ImageReview, title: String) -> FaceVisualReportSection {
            var fields = value.qualityIssues.map {
                FaceTelemetryField(key: "report.qualityIssue", value: .code("report.quality.\($0.rawValue)"))
            }
            if fields.isEmpty { fields.append(.init(key: "report.qualityIssue", value: .code("telemetry.noneReported"))) }
            fields += text("report.observation", value.observations)
            if let ages = value.apparentAge.rangeYears, ages.count == 2 {
                fields.append(.init(key: "report.ageMinimum", value: .integer(ages[0])))
                fields.append(.init(key: "report.ageMaximum", value: .integer(ages[1])))
            } else { fields.append(.init(key: "report.ageRange", value: .unavailable)) }
            fields.append(.init(key: "report.ageBasis", value: .text(value.apparentAge.basis)))
            fields += text("report.limitation", value.apparentAge.limitations)
            return .init(titleKey: title, fields: fields)
        }
        var sections = [image(report.reference, title: "report.reference.title"), image(report.selfie, title: "report.selfie.title")]
        sections.append(.init(titleKey: "report.aura.title", fields: [
            .init(key: "report.relationship", value: .code("report.aura.\(report.auraReview.relationship.rawValue)"))
        ] + text("report.evidence", report.auraReview.evidence) + text("report.limitation", report.auraReview.limitations)))
        sections.append(.init(titleKey: "report.age.title", fields: [
            .init(key: "report.relationship", value: .code("report.age.\(report.ageReview.relationship.rawValue)"))
        ] + text("report.evidence", report.ageReview.evidence) + text("report.limitation", report.ageReview.limitations)))
        sections.append(.init(titleKey: "report.capture.title",
            fields: text("report.observation", report.captureReview.observations) + text("report.limitation", report.captureReview.limitations)))
        for indicator in report.captureReview.indicators {
            sections.append(.init(titleKey: "report.indicator.\(indicator.indicator.rawValue)", fields: [
                .init(key: "report.indicator.status", value: .code("report.status.\(indicator.status.rawValue)")),
                .init(key: "report.evidence", value: .text(indicator.evidence))
            ] + text("report.sourceImage", indicator.sourceImageIds)))
        }
        return FaceVisualReport(summary: report.summary, sections: sections)
    }


}

/// Prepared, source-attributed telemetry only; missing sensor values remain missing.
enum FaceComparisonTelemetry {
    static func fields(_ input: FaceInputTelemetry, includeCaptureMotionSource: Bool = true) -> [FaceTelemetryField] {
        var fields: [FaceTelemetryField] = [
            .init(key: "telemetry.input.operationID", value: .text(input.operationID.uuidString)),
            .init(key: "telemetry.input.referenceSHA256", value: .text(input.referenceSHA256)),
            .init(key: "telemetry.input.selfieSHA256", value: .text(input.selfieSHA256)),
            .init(key: "telemetry.input.referenceBytes", value: .integer(input.referenceBytes)),
            .init(key: "telemetry.input.selfieBytes", value: .integer(input.selfieBytes))
        ]
        if let selection = input.selection {
            fields += [
                .init(key: "telemetry.selection.policy", value: .text(selection.policyID)),
                .init(key: "telemetry.selection.candidates", value: .integer(selection.candidates.count)),
                .init(key: "telemetry.selection.selectedCaptureID", value: .text(selection.selectedCaptureID.uuidString)),
                .init(key: "telemetry.selection.selectedAlignedSHA256", value: .text(selection.selectedAlignedSHA256)),
                .init(key: "telemetry.selection.qualityArtifactSHA256", value: .text(selection.qualityArtifactSHA256))
            ]
            if let winner = selection.candidates.first(where: { $0.capture.captureID == selection.selectedCaptureID }) {
                fields.append(.init(key: "telemetry.selection.index", value: .integer(winner.index + 1)))
                fields.append(.init(key: "telemetry.selection.nativeUQS", value: winner.quality?.uqs?.native.map(FaceTelemetryValue.number) ?? .unavailable))
            }
        }
        guard let context = input.captureContext else {
            fields.append(.init(key: "telemetry.capture.receipt", value: .unavailable))
            return fields
        }
        let r = context.receipt
        func add(_ key: String, _ value: FaceTelemetryValue?) { fields.append(.init(key: key, value: value ?? .unavailable)) }
        add("telemetry.capture.captureID", .text(context.captureID.uuidString))
        add("telemetry.capture.receiptSHA256", (try? FaceComparisonHost.sourceDigest(r)).map(FaceTelemetryValue.text))
        add("telemetry.capture.policyVersion", .text(r.policyVersion))
        add("telemetry.capture.trigger", .code("telemetry.trigger.\(r.trigger.rawValue)"))
        add("telemetry.capture.frameTimestamp", .number(r.frameTimestamp))
        add("telemetry.capture.anchorID", .text(r.anchorID.uuidString))
        add("telemetry.capture.trackedFrames", .integer(r.consecutiveTrackedFrames))
        add("telemetry.capture.blinkCompletedAt", .number(r.blinkCompletedAt))
        add("telemetry.capture.blinkAge", .number(r.blinkAge))
        add("telemetry.capture.leftEyeClosed", .number(Double(r.leftEyeClosed)))
        add("telemetry.capture.rightEyeClosed", .number(Double(r.rightEyeClosed)))
        add("telemetry.capture.eyesOpen", .flag(r.eyesOpen))
        add("telemetry.capture.steadyHold", .number(r.steadyHoldDuration))
        add("telemetry.capture.quality", r.captureQuality.map { .number(Double($0)) })
        add("telemetry.capture.qualityEnforced", .flag(r.captureQualityEnforced))
        add("telemetry.capture.insideGuide", r.insideGuide.map(FaceTelemetryValue.flag))
        add("telemetry.capture.guideEnforced", .flag(r.guideContainmentEnforced))
        add("telemetry.frame.sessionID", r.frameEvidence.map { .text($0.sessionID.uuidString) })
        add("telemetry.frame.sequence", r.frameEvidence.map { .unsigned($0.sequence) })
        add("telemetry.frame.guideRevision", r.frameEvidence.map { .unsigned($0.guideRevision) })
        add("telemetry.frame.width", r.frameEvidence.map { .integer($0.pixelWidth) })
        add("telemetry.frame.height", r.frameEvidence.map { .integer($0.pixelHeight) })
        add("telemetry.frame.orientation", r.frameEvidence.map { .integer(Int($0.orientation)) })
        add("telemetry.frame.qualityRevision", r.frameEvidence.map { .integer($0.qualityRevision) })
        add("telemetry.frame.analysisDuration", r.frameEvidence.map { .number($0.analysisDuration) })
        add("telemetry.frame.ageAtAdmission", r.frameEvidence.map { .number($0.frameAgeAtAdmission) })
        add("telemetry.depth.recordSHA256", r.depthEvidence.flatMap { try? FaceComparisonHost.sourceDigest($0) }.map(FaceTelemetryValue.text))
        add("telemetry.depth.imageSHA256", r.depthEvidence.map { .text($0.imageSHA256) })
        add("telemetry.depth.schemaVersion", r.depthEvidence.map { .integer($0.schemaVersion) })
        add("telemetry.depth.imageTimestamp", r.depthEvidence.map { .number($0.imageTimestamp) })
        add("telemetry.depth.depthTimestamp", r.depthEvidence.map { .number($0.depthTimestamp) })
        add("telemetry.depth.ageAtAdmission", r.depthEvidence.map { .number($0.ageAtAdmission) })
        add("telemetry.depth.orientation", r.depthEvidence.map { .integer(Int($0.orientation)) })
        add("telemetry.depth.width", r.depthEvidence.map { .integer($0.mapWidth) })
        add("telemetry.depth.height", r.depthEvidence.map { .integer($0.mapHeight) })
        add("telemetry.depth.filtered", r.depthEvidence.map { .flag($0.filtered) })
        add("telemetry.depth.sampleCount", r.depthEvidence.map { .integer($0.measurement.sampleCount) })
        add("telemetry.depth.residualRMS", r.depthEvidence?.measurement.residualRMS.map(FaceTelemetryValue.number))
        add("telemetry.depth.assessment", r.depthEvidence.map { .code("telemetry.depthAssessment.\($0.assessment.rawValue)") })
        add("telemetry.admissionPolicy.requiredTrackedFrames", r.effectivePolicy.map { .integer($0.requiredTrackedFrames) })
        add("telemetry.admissionPolicy.maximumFrameAge", r.effectivePolicy.map { .number($0.maximumFrameAge) })
        add("telemetry.admissionPolicy.blinkFreshness", r.effectivePolicy.map { .number($0.blinkFreshness) })
        add("telemetry.admissionPolicy.eyeClosedThreshold", r.effectivePolicy.map { .number(Double($0.eyeClosedThreshold)) })
        add("telemetry.admissionPolicy.steadyHold", r.effectivePolicy.map { .number($0.steadyHold) })
        add("telemetry.admissionPolicy.minimumCaptureQuality", r.effectivePolicy?.minimumCaptureQuality.map { .number(Double($0)) })
        add("telemetry.admissionPolicy.requiresGuideContainment", r.effectivePolicy.map { .flag($0.requiresGuideContainment) })
        add("telemetry.depthPolicy.identifier", r.depthEvidence.map { .text($0.measurement.policy.identifier) })
        add("telemetry.depthPolicy.minimumResidualRMS", r.depthEvidence.map { .number($0.measurement.policy.minimumResidualRMS) })
        add("telemetry.depthPolicy.minimumSamples", r.depthEvidence.map { .integer($0.measurement.policy.minimumSamples) })
        add("telemetry.depthPolicy.nearLimit", r.depthEvidence.map { .number($0.measurement.policy.nearLimit) })
        add("telemetry.depthPolicy.farLimit", r.depthEvidence.map { .number($0.measurement.policy.farLimit) })
        add("telemetry.depthPolicy.maximumDepthAge", r.depthEvidence.map { .number($0.measurement.policy.maximumDepthAge) })
        add("telemetry.depthPolicy.samplesPerAxis", r.depthEvidence.map { .integer($0.measurement.policy.samplesPerAxis) })
        add("telemetry.motion.permissionStatus", .code("telemetry.motionPermission.\(r.motionStatus.rawValue)"))
        add("telemetry.motion.imageSHA256", r.motionEvidence.map { .text($0.imageSHA256) })
        add("telemetry.motion.recordSHA256", r.motionEvidence.flatMap { try? FaceComparisonHost.sourceDigest($0) }.map(FaceTelemetryValue.text))
        add("telemetry.motion.frameTimestamp", r.motionEvidence.map { .number($0.frameTimestampSeconds) })
        add("telemetry.motion.windowStart", r.motionEvidence.map { .number($0.windowStartTimestampSeconds) })
        add("telemetry.motion.windowEnd", r.motionEvidence.map { .number($0.windowEndTimestampSeconds) })
        add("telemetry.motion.clockDomain", r.motionEvidence.map { .text($0.clockDomain) })
        add("telemetry.motion.alignment", r.motionEvidence.map { .text($0.alignment) })
        add("telemetry.motion.ceremony", r.motionEvidence.map { .code("telemetry.ceremony.\($0.summary.ceremony.rawValue)") })
        add("telemetry.motion.rawWindowSHA256", r.motionEvidence.map { .text($0.summary.rawWindowSHA256) })
        return includeCaptureMotionSource ? fields : fields.filter { !$0.key.hasPrefix("telemetry.motion.") }
    }

    static func motionFields(_ projection: WorkflowMotionProjection) -> [FaceTelemetryField] {
        var fields: [FaceTelemetryField] = [
            .init(key: "telemetry.workflowMotion.workflowID", value: .text(projection.workflowID.uuidString)),
            .init(key: "telemetry.workflowMotion.throughEventID", value: .text(projection.throughEventID.uuidString)),
            .init(key: "telemetry.workflowMotion.firstSampleAt", value: projection.firstSampleAt.map { .text($0.formatted(.iso8601)) } ?? .unavailable),
            .init(key: "telemetry.workflowMotion.lastSampleAt", value: projection.lastSampleAt.map { .text($0.formatted(.iso8601)) } ?? .unavailable),
            .init(key: "telemetry.workflowMotion.events", value: .integer(projection.eventCount)),
            .init(key: "telemetry.workflowMotion.windows", value: .integer(projection.windowCount)),
            .init(key: "telemetry.workflowMotion.samples", value: .integer(projection.sampleCount)),
            .init(key: "telemetry.workflowMotion.duplicates", value: .integer(projection.duplicateSampleCount)),
            .init(key: "telemetry.workflowMotion.segments", value: .integer(projection.segmentCount)),
            .init(key: "telemetry.workflowMotion.eventsWithoutMotion", value: .integer(projection.eventsWithoutMotion)),
            .init(key: "telemetry.workflowMotion.magneticSamples", value: .integer(projection.magneticSampleCount)),
            .init(key: "telemetry.workflowMotion.uncalibratedWindows", value: .integer(projection.uncalibratedWindowCount)),
            .init(key: "telemetry.workflowMotion.observedSeconds", value: .number(projection.observedSeconds)),
            .init(key: "telemetry.workflowMotion.gaps", value: .integer(projection.gapCount)),
            .init(key: "telemetry.workflowMotion.gapSeconds", value: .number(projection.gapSeconds))
        ]
        for permission in projection.permissions {
            fields.append(.init(key: "telemetry.motion.permissionStatus", value: .code("telemetry.motionPermission.\(permission)")))
        }
        if projection.permissions.isEmpty {
            fields.append(.init(key: "telemetry.motion.permissionStatus", value: .unavailable))
        }
        for ceremony in projection.ceremonies {
            fields.append(.init(key: "telemetry.motion.ceremony", value: .code("telemetry.ceremony.\(ceremony)")))
        }
        for axis in projection.gravityAxes {
            fields.append(.init(key: "telemetry.motion.gravityAxis", value: .text(axis)))
        }
        for key in ["accelerationX", "accelerationY", "accelerationZ", "accelerationMagnitude",
                    "rotationX", "rotationY", "rotationZ", "rotationMagnitude",
                    "gravityX", "gravityY", "gravityZ", "gravityMagnitude", "magneticMagnitude",
                    "requestedSampleRate", "windowSampleCount", "windowDuration", "accelerationRMS",
                    "rotationRMS", "tremorRatio", "gravityDominance", "gravityDrift", "approachRMS",
                    "settleRatio", "magneticDelta"] {
            let value: FaceTelemetryValue = projection.ranges[key].map { .range($0.minimum, $0.maximum) } ?? .unavailable
            fields.append(.init(key: "telemetry.workflowMotion.\(key)", value: value))
        }
        return fields
    }
}
