import Foundation
import XCTest

@testable import DocumentCaptureJournal
@testable import DocumentCaptureApple

@MainActor
final class TiltGuidanceVersionBindingTests: XCTestCase {
  func testJournalRejectsPolicyOrCapacityChangesWithinOneRun() async throws {
    for variant in 0..<4 {
      let fixture = try RecordingFixture()
      defer { fixture.cleanup() }
      let journal = try await CaptureRecordingJournal.start(
        workflowID: UUID(), store: fixture.store, clock: .fixture)
      let initialConfiguration: DocumentTiltConfiguration =
        variant == 2 ? .provisionalV2 : .provisionalV1
      let first = DocumentTiltController(runID: UUID(), configuration: initialConfiguration)
        .initialUpdate
      var configuration = initialConfiguration
      if variant == 1 { configuration = .provisionalV2 }
      if variant == 2 { configuration = .provisionalV1 }
      if variant == 3 { configuration = .init(evidenceSampleLimit: 32) }
      let next = try revised(first, configuration: configuration)
      XCTAssertTrue(first.valid && next.valid)
      journal.appendEvent(.init(kind: "tilt_guidance", hostTimeSeconds: 1, tiltGuidance: first))
      journal.appendEvent(.init(kind: "tilt_guidance", hostTimeSeconds: 2, tiltGuidance: next))
      _ = try await journal.finish(reason: "operator_stop")
      do {
        _ = try await CaptureRecordingVerification.verify(
          journal.reference, store: fixture.store)
        XCTAssertEqual(variant, 0, "Changed run configuration accepted")
      } catch {
        XCTAssertNotEqual(variant, 0, "Frozen run rejected: \(error)")
      }
    }
  }

  private func revised(
    _ update: DocumentTiltUpdate, configuration: DocumentTiltConfiguration
  ) throws -> DocumentTiltUpdate {
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
    for key in ["presentation", "event"] {
      var state = try XCTUnwrap(object[key] as? [String: Any])
      state["revision"] = 2
      if key == "event" {
        state["configurationVersion"] = configuration.version
        state["configuration"] = try JSONSerialization.jsonObject(
          with: JSONEncoder().encode(configuration))
      }
      object[key] = state
    }
    return try JSONDecoder().decode(
      DocumentTiltUpdate.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
