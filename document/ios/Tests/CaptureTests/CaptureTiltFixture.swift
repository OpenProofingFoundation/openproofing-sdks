#if os(iOS)
  import CoreLocation
  import CryptoKit
  import Foundation
  import DocumentCaptureApple
  @_spi(CaptureTestFixture) @testable import CaptureEvidenceCustody
  @testable import DocumentCaptureJournal
  @testable import DocumentCapture

  extension CaptureRecordingClock {
    static var tiltFixture: Self {
      .init(
        now: { Date(timeIntervalSince1970: 1_700_000_000) },
        uptime: { ProcessInfo.processInfo.systemUptime })
    }
  }

  struct TiltMechanismFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store: CaptureEvidenceStore
    init() throws { store = try .init(directory: directory, key: SymmetricKey(size: .bits256)) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
  }

  @MainActor
  struct TiltTestActions {
    var begin: CaptureSessionTiltActions.Begin = { camera, id in
      try await camera.beginTiltGuidance(runID: id, configuration: .provisionalV2)
    }
    var end: CaptureSessionTiltActions.End = { camera, id, reason in
      await camera.endTiltGuidance(runID: id, reason: reason)
    }
  }

  @MainActor
  func makeTiltSession(
    capturePhoto: (
      @MainActor (DocumentCamera, DocumentCaptureRequest) async throws -> CapturedDocumentPhoto
    )? = nil,
    tiltActions: TiltTestActions = .init(), presence: DocumentPresencePolicy? = nil
  ) -> CaptureSession {
    let namespace = UUID().uuidString
    let configuration = try! CaptureCustodyConfiguration(
      applicationID: "synthetic.capture-sdk.fixture", directory: FileManager.default.temporaryDirectory.appendingPathComponent(namespace),
      keychainService: "synthetic.capture-tilt-mechanism-tests.\(namespace)", keychainAccount: "fixture", accessGroup: "TEST.capture-sdk.fixture")
    let session = CaptureSession(
      configuration: .init(
        notifications: NotificationCenter(),
        custody: configuration,
        signing: try! .testing(applicationID: "synthetic.capture-sdk.fixture", installationID: "synthetic-installation"),
        clock: .tiltFixture, consent: .permitted, documentPresence: presence)).withFixtureCustody()
    session.location = .init(
      manager: TiltFixtureLocation(), now: CaptureRecordingClock.tiltFixture.now)
    session.tiltActions.begin = tiltActions.begin
    session.tiltActions.end = tiltActions.end
    if let capturePhoto { session.capturePhoto = capturePhoto }
    return session
  }
  @MainActor
  private final class TiltFixtureLocation: CaptureSessionLocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus { .authorizedWhenInUse }
    func requestWhenInUseAuthorization() {}
    func startUpdatingLocation() {}
    func stopUpdatingLocation() {}
  }
#endif
