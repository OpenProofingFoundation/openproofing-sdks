import Foundation

/// How often the journey recording is offered a camera frame.
///
/// ATTRIBUTION. An engineering default set on 2026-09-22, not measured against any population.
/// Offering every camera frame at 30 fps cost about three megabytes a frame and a hundred
/// megabytes a second: one scan wrote half a gigabyte, and the phone paid for it at capture, at
/// launch and before every later scan. Two frames a second keep the journey's timeline and
/// geometry with a fiftieth of the bytes. The in-memory ring, which decides capture quality, is
/// not paced and still sees every frame.
///
/// RECORDED IN THE RESULT. Every `session_started` event the journal receives carries
/// `identifier` as its contextCode, so a reader of a journal can see which pacing produced it.
struct DocumentJourneyPacing: Equatable, Sendable {
  let identifier: String
  let minimumFrameIntervalSeconds: Double

  static let engineering20260922 = Self()

  private init() {
    identifier = "document_journey_pacing_2026_09_v1"
    minimumFrameIntervalSeconds = 0.5
  }
}
