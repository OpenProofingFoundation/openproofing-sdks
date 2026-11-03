import Foundation

/// Host-supplied scalar measurements from the admitted selfie. Hashes bind supplied
/// records; this value does not authenticate a sensor or establish liveness.
public struct CaptureMeasurements: Sendable {
    public struct Binding: Sendable {
        public let imageSHA256: String
        public let sourceSHA256: String
        public let frameTimestampSeconds: Double
        public let clockDomain: String
        public init(imageSHA256: String, sourceSHA256: String, frameTimestampSeconds: Double, clockDomain: String) {
            self.imageSHA256 = imageSHA256; self.sourceSHA256 = sourceSHA256
            self.frameTimestampSeconds = frameTimestampSeconds; self.clockDomain = clockDomain
        }
    }
    public struct Depth: Sendable {
        public struct Timing: Sendable {
            public let imageTimestampSeconds: Double
            public let depthTimestampSeconds: Double
            public let ageAtAdmissionSeconds: Double
            public init(imageTimestampSeconds: Double, depthTimestampSeconds: Double, ageAtAdmissionSeconds: Double) {
                self.imageTimestampSeconds = imageTimestampSeconds; self.depthTimestampSeconds = depthTimestampSeconds
                self.ageAtAdmissionSeconds = ageAtAdmissionSeconds
            }
        }
        public struct Map: Sendable {
            public let width: Int
            public let height: Int
            public let filtered: Bool
            public init(width: Int, height: Int, filtered: Bool) {
                self.width = width; self.height = height; self.filtered = filtered
            }
        }
        public let sourceSHA256: String
        public let timing: Timing
        public let map: Map
        public let sampleCount: Int
        public let residualRMSMetres: Double?
        public init(sourceSHA256: String, timing: Timing, map: Map, sampleCount: Int, residualRMSMetres: Double?) {
            self.sourceSHA256 = sourceSHA256; self.timing = timing; self.map = map
            self.sampleCount = sampleCount; self.residualRMSMetres = residualRMSMetres
        }
    }
    public struct Blink: Sendable {
        public let completedAtSeconds: Double
        public let ageSeconds: Double
        public let leftEyeClosed: Double
        public let rightEyeClosed: Double
        public let eyesOpen: Bool
        public init(completedAtSeconds: Double, ageSeconds: Double, leftEyeClosed: Double,
                    rightEyeClosed: Double, eyesOpen: Bool) {
            self.completedAtSeconds = completedAtSeconds; self.ageSeconds = ageSeconds
            self.leftEyeClosed = leftEyeClosed; self.rightEyeClosed = rightEyeClosed; self.eyesOpen = eyesOpen
        }
    }
    public struct Tracking: Sendable {
        public let consecutiveFrames: Int
        public let steadyHoldSeconds: Double
        public init(consecutiveFrames: Int, steadyHoldSeconds: Double) {
            self.consecutiveFrames = consecutiveFrames; self.steadyHoldSeconds = steadyHoldSeconds
        }
    }
    public struct Quality: Sendable {
        public let score: Double?
        public let revision: Int?
        public let insideGuide: Bool?
        public let analysisDurationSeconds: Double?
        public let frameAgeAtAdmissionSeconds: Double?
        public init(score: Double?, revision: Int?, insideGuide: Bool?, analysisDurationSeconds: Double?,
                    frameAgeAtAdmissionSeconds: Double?) {
            self.score = score; self.revision = revision; self.insideGuide = insideGuide
            self.analysisDurationSeconds = analysisDurationSeconds; self.frameAgeAtAdmissionSeconds = frameAgeAtAdmissionSeconds
        }
    }
    public let binding: Binding
    public let depth: Depth?
    public let blink: Blink?
    public let tracking: Tracking?
    public let quality: Quality?
    public let motion: Motion?
    public init(binding: Binding, depth: Depth?, blink: Blink?, tracking: Tracking?, quality: Quality?, motion: Motion? = nil) {
        self.binding = binding; self.depth = depth; self.blink = blink; self.tracking = tracking; self.quality = quality; self.motion = motion
    }

    func validate(selfieSHA256: String) throws {
        guard binding.imageSHA256 == selfieSHA256, ReviewJSON.isDigest(binding.imageSHA256),
              ReviewJSON.isDigest(binding.sourceSHA256), Self.nonnegative(binding.frameTimestampSeconds),
              binding.clockDomain == "arkit_session_seconds" else { throw VisualFaceAssessmentFailure.sourceMismatch }
        if let depth {
            let timing = depth.timing
            guard ReviewJSON.isDigest(depth.sourceSHA256), timing.imageTimestampSeconds == binding.frameTimestampSeconds,
                  Self.nonnegative(timing.depthTimestampSeconds), timing.depthTimestampSeconds <= timing.imageTimestampSeconds,
                  Self.nonnegative(timing.ageAtAdmissionSeconds),
                  timing.ageAtAdmissionSeconds >= timing.imageTimestampSeconds - timing.depthTimestampSeconds,
                  depth.map.width > 0, depth.map.width <= LiquidProfile.maximumDimension,
                  depth.map.height > 0, depth.map.height <= LiquidProfile.maximumDimension,
                  depth.map.width <= LiquidProfile.maximumPixels / depth.map.height,
                  depth.sampleCount >= 0, depth.sampleCount <= depth.map.width * depth.map.height,
                  depth.residualRMSMetres.map(Self.nonnegative) ?? true else {
                throw VisualFaceAssessmentFailure.sourceMismatch
            }
        }
        if let blink {
            guard Self.nonnegative(blink.completedAtSeconds), blink.completedAtSeconds <= binding.frameTimestampSeconds,
                  Self.nonnegative(blink.ageSeconds),
                  blink.ageSeconds >= binding.frameTimestampSeconds - blink.completedAtSeconds,
                  Self.unit(blink.leftEyeClosed), Self.unit(blink.rightEyeClosed) else {
                throw VisualFaceAssessmentFailure.sourceMismatch
            }
        }
        if let tracking {
            guard tracking.consecutiveFrames >= 0, tracking.consecutiveFrames <= Int(Int32.max), Self.nonnegative(tracking.steadyHoldSeconds) else {
                throw VisualFaceAssessmentFailure.sourceMismatch
            }
        }
        try motion?.validate(frameTimestampSeconds: binding.frameTimestampSeconds)
        if let quality {
            guard quality.score.map(Self.unit) ?? true, quality.revision.map({ $0 >= 0 && $0 <= Int(Int32.max) }) ?? true,
                  quality.analysisDurationSeconds.map(Self.nonnegative) ?? true,
                  quality.frameAgeAtAdmissionSeconds.map(Self.nonnegative) ?? true else {
                throw VisualFaceAssessmentFailure.sourceMismatch
            }
        }
    }

    private static func nonnegative(_ value: Double) -> Bool { value.isFinite && value >= 0 }
    private static func unit(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }

    func json() -> ReviewJSON {
        .object([
            "status": .string("available"), "imageSHA256": .string(binding.imageSHA256),
            "sourceSHA256": .string(binding.sourceSHA256), "frameTimestampSeconds": .number(binding.frameTimestampSeconds),
            "clockDomain": .string(binding.clockDomain),
            "depth": depth.map { .object([
                "sourceSHA256": .string($0.sourceSHA256), "imageTimestampSeconds": .number($0.timing.imageTimestampSeconds),
                "depthTimestampSeconds": .number($0.timing.depthTimestampSeconds),
                "ageAtAdmissionSeconds": .number($0.timing.ageAtAdmissionSeconds),
                "mapWidth": .number(Double($0.map.width)), "mapHeight": .number(Double($0.map.height)),
                "filtered": .bool($0.map.filtered), "sampleCount": .number(Double($0.sampleCount)),
                "residualRMSMetres": $0.residualRMSMetres.map(ReviewJSON.number) ?? .null
            ]) } ?? .null,
            "blink": blink.map { .object([
                "completedAtSeconds": .number($0.completedAtSeconds), "ageSeconds": .number($0.ageSeconds),
                "leftEyeClosed": .number($0.leftEyeClosed), "rightEyeClosed": .number($0.rightEyeClosed),
                "eyesOpen": .bool($0.eyesOpen)
            ]) } ?? .null,
            "tracking": tracking.map { .object([
                "consecutiveFrames": .number(Double($0.consecutiveFrames)), "steadyHoldSeconds": .number($0.steadyHoldSeconds)
            ]) } ?? .null,
            "motion": motion?.json() ?? .null,
            "quality": quality.map { .object([
                "score": $0.score.map(ReviewJSON.number) ?? .null,
                "revision": $0.revision.map { .number(Double($0)) } ?? .null,
                "insideGuide": $0.insideGuide.map(ReviewJSON.bool) ?? .null,
                "analysisDurationSeconds": $0.analysisDurationSeconds.map(ReviewJSON.number) ?? .null,
                "frameAgeAtAdmissionSeconds": $0.frameAgeAtAdmissionSeconds.map(ReviewJSON.number) ?? .null
            ]) } ?? .null
        ])
    }
}

/// A source-bound embedding observation supplied by the host, not an SDK threshold.
public struct AuraContext: Sendable {
    public let cosineSimilarity: Double
    public let interpretation: String
    public let policyId: String?
    public let resultSHA256: String
    public let referenceSHA256: String
    public let selfieSHA256: String
    public init(cosineSimilarity: Double, interpretation: String, policyId: String?, resultSHA256: String,
                referenceSHA256: String, selfieSHA256: String) {
        self.cosineSimilarity = cosineSimilarity; self.interpretation = interpretation; self.policyId = policyId
        self.resultSHA256 = resultSHA256; self.referenceSHA256 = referenceSHA256; self.selfieSHA256 = selfieSHA256
    }
    func validate(referenceSHA256: String, selfieSHA256: String) throws {
        guard self.referenceSHA256 == referenceSHA256, self.selfieSHA256 == selfieSHA256,
              ReviewJSON.isDigest(resultSHA256), cosineSimilarity.isFinite, (-1...1).contains(cosineSimilarity),
              (1...240).contains(interpretation.unicodeScalars.count),
              interpretation.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil,
              !interpretation.unicodeScalars.contains(where: { [.control, .format, .surrogate].contains($0.properties.generalCategory) }),
              policyId.map(ReviewJSON.isIdentifier) ?? true else { throw VisualFaceAssessmentFailure.sourceMismatch }
    }
    func json() -> ReviewJSON {
        .object(["status": .string("available"), "cosineSimilarity": .number(cosineSimilarity),
                 "interpretation": .string(interpretation), "policyId": policyId.map(ReviewJSON.string) ?? .null,
                 "resultSHA256": .string(resultSHA256), "referenceSHA256": .string(referenceSHA256),
                 "selfieSHA256": .string(selfieSHA256)])
    }
}

extension CaptureMeasurements {
    /// An independently sampled device-motion window aligned by the host to the still.
    /// This is not an image sequence or a hardware-signed sensor attestation.
    public struct Motion: Sendable {
        public struct Statistics: Sendable {
            public let accelerationRMSg: Double?
            public let rotationRMSRadPerSecond: Double?
            public let tremorBandRatio: Double?
            public let approachRMSg: Double?
            public let settleRatio: Double?
            public init(accelerationRMSg: Double?, rotationRMSRadPerSecond: Double?, tremorBandRatio: Double?,
                        approachRMSg: Double?, settleRatio: Double?) {
                self.accelerationRMSg = accelerationRMSg; self.rotationRMSRadPerSecond = rotationRMSRadPerSecond
                self.tremorBandRatio = tremorBandRatio; self.approachRMSg = approachRMSg; self.settleRatio = settleRatio
            }
        }
        public struct Gravity: Sendable {
            public enum Axis: String, Sendable { case x, y, z }
            public let dominantAxis: Axis?
            public let dominance: Double?
            public let driftRadians: Double?
            public init(dominantAxis: Axis?, dominance: Double?, driftRadians: Double?) {
                self.dominantAxis = dominantAxis; self.dominance = dominance; self.driftRadians = driftRadians
            }
        }
        public struct Magnetic: Sendable {
            public let deltaMicrotesla: Double?
            public let calibrated: Bool
            public init(deltaMicrotesla: Double?, calibrated: Bool) {
                self.deltaMicrotesla = deltaMicrotesla; self.calibrated = calibrated
            }
        }
        public struct Summary: Sendable {
            public let sampleCount: Int
            public let durationSeconds: Double
            public let statistics: Statistics
            public let gravity: Gravity
            public let magnetic: Magnetic
            public let rawWindowSHA256: String
            public init(sampleCount: Int, durationSeconds: Double, statistics: Statistics,
                        gravity: Gravity, magnetic: Magnetic, rawWindowSHA256: String) {
                self.sampleCount = sampleCount; self.durationSeconds = durationSeconds; self.statistics = statistics
                self.gravity = gravity; self.magnetic = magnetic; self.rawWindowSHA256 = rawWindowSHA256
            }
        }
        public let sourceSHA256: String
        public let frameTimestampSeconds: Double
        public let windowStartTimestampSeconds: Double
        public let windowEndTimestampSeconds: Double
        public let requestedSampleRateHz: Double
        public let summary: Summary
        public init(sourceSHA256: String, frameTimestampSeconds: Double, windowStartTimestampSeconds: Double,
                    windowEndTimestampSeconds: Double, requestedSampleRateHz: Double, summary: Summary) {
            self.sourceSHA256 = sourceSHA256; self.frameTimestampSeconds = frameTimestampSeconds
            self.windowStartTimestampSeconds = windowStartTimestampSeconds
            self.windowEndTimestampSeconds = windowEndTimestampSeconds
            self.requestedSampleRateHz = requestedSampleRateHz; self.summary = summary
        }
        fileprivate func validate(frameTimestampSeconds: Double) throws {
            let statistics = summary.statistics
            let nonnegative: [Double?] = [windowStartTimestampSeconds, windowEndTimestampSeconds,
                requestedSampleRateHz, summary.durationSeconds, statistics.accelerationRMSg,
                statistics.rotationRMSRadPerSecond, statistics.approachRMSg, statistics.settleRatio,
                summary.gravity.driftRadians, summary.magnetic.deltaMicrotesla]
            let units = [statistics.tremorBandRatio, summary.gravity.dominance]
            guard ReviewJSON.isDigest(sourceSHA256), ReviewJSON.isDigest(summary.rawWindowSHA256),
                  self.frameTimestampSeconds == frameTimestampSeconds,
                  nonnegative.allSatisfy({ $0.map { $0.isFinite && $0 >= 0 } ?? true }),
                  units.allSatisfy({ $0.map { $0.isFinite && (0...1).contains($0) } ?? true }),
                  windowStartTimestampSeconds < windowEndTimestampSeconds, windowEndTimestampSeconds <= frameTimestampSeconds,
                  frameTimestampSeconds - windowEndTimestampSeconds <= LiquidReviewProfile.motionMaximumFrameGap,
                  requestedSampleRateHz == LiquidReviewProfile.motionSampleRate,
                  summary.sampleCount >= LiquidReviewProfile.motionMinimumSamples,
                  summary.sampleCount <= LiquidReviewProfile.motionMaximumSamples,
                  summary.durationSeconds <= LiquidReviewProfile.motionMaximumDuration,
                  summary.gravity.driftRadians.map({ $0 <= .pi }) ?? true,
                  abs(summary.durationSeconds - (windowEndTimestampSeconds - windowStartTimestampSeconds))
                    <= LiquidReviewProfile.clockTolerance else {
                throw VisualFaceAssessmentFailure.sourceMismatch
            }
        }
        fileprivate func json() -> ReviewJSON {
            .object([
                "sourceSHA256": .string(sourceSHA256), "frameTimestampSeconds": .number(frameTimestampSeconds),
                "windowStartTimestampSeconds": .number(windowStartTimestampSeconds),
                "windowEndTimestampSeconds": .number(windowEndTimestampSeconds),
                "requestedSampleRateHz": .number(requestedSampleRateHz),
                "clockDomain": .string("core_motion_boot_seconds"), "alignment": .string("host_uptime_checked"),
                "summary": .object([
                    "ceremony": .string("face_match"), "sampleCount": .number(Double(summary.sampleCount)),
                    "durationSeconds": .number(summary.durationSeconds),
                    "accelerationRMSg": summary.statistics.accelerationRMSg.map(ReviewJSON.number) ?? .null,
                    "rotationRMSRadPerSecond": summary.statistics.rotationRMSRadPerSecond.map(ReviewJSON.number) ?? .null,
                    "tremorBandRatio": summary.statistics.tremorBandRatio.map(ReviewJSON.number) ?? .null,
                    "approachRMSg": summary.statistics.approachRMSg.map(ReviewJSON.number) ?? .null,
                    "settleRatio": summary.statistics.settleRatio.map(ReviewJSON.number) ?? .null,
                    "gravityDominantAxis": summary.gravity.dominantAxis.map { .string($0.rawValue) } ?? .null,
                    "gravityDominance": summary.gravity.dominance.map(ReviewJSON.number) ?? .null,
                    "gravityDriftRadians": summary.gravity.driftRadians.map(ReviewJSON.number) ?? .null,
                    "magneticDeltaMicrotesla": summary.magnetic.deltaMicrotesla.map(ReviewJSON.number) ?? .null,
                    "magnetometerCalibrated": .bool(summary.magnetic.calibrated),
                    "rawWindowSHA256": .string(summary.rawWindowSHA256)
                ])
            ])
        }
    }
}
