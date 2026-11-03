import DocumentCaptureApple
import DocumentCapturePreview
import Foundation
import UIKit

/// Product copy/theme mapping only; capture readiness remains authoritative in the SDK.
@MainActor enum DocumentFrontCapturePresentation {
    static func state(front: DocumentFrontCaptureController, busy: Bool, uptime: Double) -> DocumentFrontCaptureState {
        let level = DocumentLevelPresentation.state(sample: front.latestMotion, uptime: uptime)
        let levelKey: String
        switch level.tone {
        case .unavailable: levelKey = "document.front.level.unavailable"
        case .centered: levelKey = "document.front.level.centered"
        case .warning: levelKey = "document.front.level.warning"
        case .tilted: levelKey = "document.front.level.tilted"
        }
        let status: String
        if busy { status = "document.live.processing.body" }
        else if front.latestQuality == nil { status = "document.front.quality.cameraAdjusting" }
        else if let reason = front.latestQuality?.assessment.blockingReasons.first {
            status = qualityKey(reason)
        } else { status = front.automaticCaptureAvailable ? "document.front.ready" : "document.front.manual" }
        return .init(heading: copy("workflow.step.document.front"), instruction: copy("document.front.instruction"),
            status: copy(status), captureTitle: copy("document.front.capture"), cancelTitle: copy("document.front.cancel"),
            previewAccessibilityLabel: copy("document.live.preview"), levelAccessibilityLabel: copy("document.front.level.label"),
            levelAccessibilityValue: copy(levelKey), level: level,
            captureEnabled: front.manualCaptureAvailable && !busy, busy: busy, showLevel: true)
    }

    private static func qualityKey(_ reason: DocumentCaptureQualityAssessment.BlockingReason) -> String {
        switch reason {
        case .documentNotFound: return "document.front.quality.documentNotFound"
        case .guideUnavailable: return "document.front.quality.guideUnavailable"
        case .alignWithGuide: return "document.front.quality.alignWithGuide"
        case .moveCloser: return "document.front.quality.moveCloser"
        case .moveFartherAway: return "document.front.quality.moveFartherAway"
        case .tooDark: return "document.front.quality.tooDark"
        case .tooBright: return "document.front.quality.tooBright"
        case .glare: return "document.front.quality.glare"
        case .holdSteady: return "document.front.quality.holdSteady"
        case .softFocus: return "document.front.quality.softFocus"
        case .stabilizing: return "document.front.quality.stabilizing"
        case .cameraAdjusting: return "document.front.quality.cameraAdjusting"
        }
    }

    static func style() -> DocumentFrontCaptureStyle {
        .init(fonts: .init(heading: KenshikiIOSDesign.font(.title), body: KenshikiIOSDesign.font(.body),
            status: KenshikiIOSDesign.font(.body), action: KenshikiIOSDesign.font(.action)),
            colors: .init(background: KenshikiIOSDesign.color(.background), text: KenshikiIOSDesign.color(.text),
                secondaryText: KenshikiIOSDesign.color(.secondary), previewBackground: KenshikiIOSDesign.color(.cameraBackground),
                previewBorder: KenshikiIOSDesign.color(.separator), levelBackground: KenshikiIOSDesign.color(.surface),
                levelLine: KenshikiIOSDesign.color(.secondary), levelGood: KenshikiIOSDesign.color(.levelGood),
                levelWarning: KenshikiIOSDesign.color(.levelWarning), levelTilted: KenshikiIOSDesign.color(.levelTilted),
                captureBackground: KenshikiIOSDesign.color(.text), captureForeground: KenshikiIOSDesign.color(.background),
                cancelForeground: KenshikiIOSDesign.color(.accent)),
            layout: .init(insets: .init(top: KenshikiDesign.pageSpacing, leading: KenshikiDesign.pageSpacing,
                bottom: KenshikiDesign.pageSpacing, trailing: KenshikiDesign.pageSpacing),
                sectionSpacing: KenshikiDesign.gapSpacing, guidanceSpacing: KenshikiDesign.compactSpacing,
                previewAspectRatio: KenshikiDesign.documentPreviewWidth / KenshikiDesign.documentPreviewHeight,
                previewCornerRadius: KenshikiDesign.cardRadius, borderWidth: KenshikiDesign.borderWidth,
                levelDiameter: KenshikiDesign.documentLevelDiameter, levelTravel: KenshikiDesign.documentLevelTravel,
                levelInnerDiameter: KenshikiDesign.documentLevelInnerDiameter, levelBubbleDiameter: KenshikiDesign.documentLevelBubbleDiameter,
                levelCrosshairLength: KenshikiDesign.documentLevelCrosshairLength, controlHeight: KenshikiDesign.minimumTargetIOS,
                controlCornerRadius: KenshikiDesign.buttonRadius, statusMinimumHeight: KenshikiDesign.documentStatusMinimumHeight))
    }

    private static func copy(_ key: String) -> String { KenshikiCopy.text(key) }
}
