import Foundation
import UIKit
@testable import KenshikiReference
import XCTest

@MainActor final class WorkflowRecoveryTests: XCTestCase {
    func testMRZSurvivesReopenBeforeAnyNFCReadAndRejectsChangedFields() async throws {
        let fixture = try CaptureStoreFixture()
        defer { fixture.remove() }
        let fields = PassportManualAccessFields(documentNumber: "L898902C3", birthDateYYMMDD: "740812", expiryDateYYMMDD: "120415")
        let lines = ["P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<", "L898902C36UTO7408122F1204159ZE184226B<<<<<10"]
        let capture = try SavedMRZCapture(fields: fields, lines: lines)
        let event = SavedWorkflowEvent(workflowID: UUID(), action: "passport.mrz.captured",
            captureID: capture.id, mrz: capture)
        try await fixture.repository().appendWorkflowEvent(event)
        let reopened = fixture.repository()
        let saved = try await reopened.loadLatestMRZ()
        XCTAssertEqual(saved?.id, capture.id)
        XCTAssertEqual(saved?.fields, fields)
        XCTAssertEqual(saved?.normalizedLines, lines)
        let nfc = try await reopened.load()
        XCTAssertNil(nfc)
        XCTAssertThrowsError(try SavedMRZCapture(fields: .init(documentNumber: "OTHER", birthDateYYMMDD: "740812",
            expiryDateYYMMDD: "120415"), lines: lines))
    }



    func testInterruptedCaptureRestoresAsIncompleteWithoutInventedOutcomes() async throws {
        let capture = try savedCapture()
        let comparison = FaceComparisonController(compare: { _ in
            XCTFail("Restoring must not run inference")
            throw FaceWorkflowStorageFailure.unavailable
        })
        try comparison.restore(capture, aura: nil, liquid: nil)
        XCTAssertEqual(comparison.phase, .failed("comparison.error.interrupted"))
        XCTAssertEqual(comparison.visualPhase, .idle)
        XCTAssertTrue(comparison.canExportReport)
        XCTAssertEqual(comparison.inputTelemetry?.selfieSHA256, capture.input.selfieSHA256)
    }

    private func savedCapture() throws -> SavedFaceCapture {
        let passport = try CaptureStoreFixture.capture()
        let reference = try XCTUnwrap(passport.nfc.portrait)
        let selfie = Data("synthetic-recovery-selfie".utf8)
        return try SavedFaceCapture(input: .init(operationID: UUID(), reference: reference,
            referenceSHA256: SavedPassportCapture.digest(reference), selfie: selfie,
            selfieSHA256: SavedPassportCapture.digest(selfie), passport: passport, workflowID: UUID()))
    }
    private func wait(_ ready: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(ready())
    }
    private func find(_ id: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == id { return button }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
}

private actor RecoveryEngines {
    private var auraCalls = 0, liquidCalls = 0
    private var score: Double?
    func aura(_ input: FaceComparisonInput) -> FaceComparisonCompletion {
        auraCalls += 1
        return .init(operationID: input.operationID, referenceSHA256: input.referenceSHA256,
            selfieSHA256: input.selfieSHA256, score: 0.9, resultSHA256: String(repeating: "b", count: 64))
    }
    func liquid(_ input: FaceVisualAssessmentInput) -> FaceVisualAssessmentCompletion {
        liquidCalls += 1; score = input.aura?.score
        return .init(operationID: input.operationID, referenceSHA256: input.referenceSHA256,
            selfieSHA256: input.selfieSHA256, consistency: nil, issues: [], durationMilliseconds: 3,
            report: .init(summary: "Synthetic recovered assessment", sections: []))
    }
    func counts() -> (aura: Int, liquid: Int, observedScore: Double?) { (auraCalls, liquidCalls, score) }
}
