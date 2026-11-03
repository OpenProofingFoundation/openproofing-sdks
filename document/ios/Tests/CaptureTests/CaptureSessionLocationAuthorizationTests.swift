#if os(iOS)
  import CoreLocation
  import DocumentCaptureJournal
  @_spi(CaptureTestFixture) import CaptureEvidenceCustody
  import XCTest

  @testable import DocumentCapture

  @MainActor
  final class CaptureSessionLocationAuthorizationTests: XCTestCase {
    func testFirstRequestWaitsForPermissionWithoutStartingFixes() async {
      let manager = LocationManagerStub()
      let provider = CaptureSessionLocation(
        manager: manager, now: { Date(timeIntervalSince1970: 123) }, diagnostic: { _ in })
      let result = Task { await provider.requestPermission() }
      await manager.waitForRequest()
      XCTAssertEqual(manager.requests, 1)
      XCTAssertEqual(manager.starts, 0)
      manager.resolve(.authorizedWhenInUse)
      let allowed = await result.value
      XCTAssertTrue(allowed)
      XCTAssertEqual(manager.starts, 0)
      XCTAssertTrue(provider.startUpdatesIfAuthorized())
      XCTAssertEqual(manager.starts, 1)
    }

    func testConcurrentCallsShareOnePromptAndDenialResolvesAll() async {
      let manager = LocationManagerStub()
      let provider = CaptureSessionLocation(
        manager: manager, now: { Date(timeIntervalSince1970: 123) }, diagnostic: { _ in })
      let first = Task { await provider.requestPermission() }
      await manager.waitForRequest()
      let second = Task { await provider.requestPermission() }
      await Task.yield()
      XCTAssertEqual(manager.requests, 1)
      manager.resolve(.denied)
      let values = await (first.value, second.value)
      XCTAssertFalse(values.0)
      XCTAssertFalse(values.1)
      XCTAssertFalse(provider.startUpdatesIfAuthorized())
      XCTAssertEqual(provider.status, .denied)
    }

    func testAllowedAndRestrictedDoNotRequestPermission() async {
      for status in [
        CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways, .denied, .restricted,
      ] {
        let manager = LocationManagerStub(status)
        let provider = CaptureSessionLocation(
          manager: manager, now: { Date(timeIntervalSince1970: 123) }, diagnostic: { _ in })
        let allowed = await provider.requestPermission()
        XCTAssertEqual(allowed, status == .authorizedWhenInUse || status == .authorizedAlways)
        XCTAssertEqual(manager.requests, 0)
        XCTAssertEqual(manager.starts, 0)
      }
    }

    func testStopResolvesWaiterAndLateGrantCannotRestartUpdates() async {
      let manager = LocationManagerStub()
      let provider = CaptureSessionLocation(
        manager: manager, now: { Date(timeIntervalSince1970: 123) }, diagnostic: { _ in })
      let first = Task { await provider.requestPermission() }
      await manager.waitForRequest()
      provider.stop()
      let cancelled = await first.value
      XCTAssertFalse(cancelled)
      manager.resolve(.authorizedWhenInUse)
      XCTAssertEqual(provider.permissionStatus, .authorizedWhenInUse)
      XCTAssertEqual(manager.starts, 0)
      let resumed = await provider.requestPermission()
      XCTAssertTrue(resumed)
      XCTAssertEqual(manager.requests, 1)
      XCTAssertEqual(manager.starts, 0)
    }

    func testResumeWhilePromptPendingDoesNotRequestAnotherSheet() async {
      let manager = LocationManagerStub()
      let provider = CaptureSessionLocation(
        manager: manager, now: { Date(timeIntervalSince1970: 123) }, diagnostic: { _ in })
      let first = Task { await provider.requestPermission() }
      await manager.waitForRequest()
      provider.stop()
      _ = await first.value
      let resumed = Task { await provider.requestPermission() }
      await Task.yield()
      XCTAssertEqual(manager.requests, 1)
      manager.resolve(.authorizedWhenInUse)
      let allowed = await resumed.value
      XCTAssertTrue(allowed)
      XCTAssertEqual(manager.starts, 0)
    }

    func testCancelledTaskCompletesWithoutAuthorizationCallback() async {
      let manager = LocationManagerStub()
      let provider = CaptureSessionLocation(
        manager: manager, now: { Date(timeIntervalSince1970: 123) }, diagnostic: { _ in })
      let task = Task { await provider.requestPermission() }
      await manager.waitForRequest()
      task.cancel()
      let allowed = await task.value
      XCTAssertFalse(allowed)
      XCTAssertEqual(manager.starts, 0)
    }

  }

  @MainActor
  final class CaptureSessionLocationIntegrationTests: XCTestCase {
    func testPermissionDenialPrecedesCustodyJournalAndCamera() async throws {
      let fixture = try LocationSessionFixture()
      defer { fixture.cleanup() }
      fixture.session.start()
      await fixture.manager.waitForRequest()
      XCTAssertNil(fixture.session.store)
      XCTAssertNil(fixture.session.recordingJournal)
      XCTAssertFalse(fixture.session.ready)
      fixture.manager.resolve(.denied)
      await fixture.session.operation?.value
      XCTAssertNil(fixture.session.store)
      XCTAssertNil(fixture.session.recordingJournal)
      XCTAssertFalse(fixture.session.ready)
      XCTAssertEqual(fixture.session.issue, .locationRequired)
      XCTAssertEqual(fixture.manager.starts, 0)
      fixture.session.stop()
    }

    func testManualRetryRestartsAuthorizedFixesButCannotCaptureWithoutFreshFix() async throws {
      let fixture = try LocationSessionFixture(.authorizedWhenInUse)
      defer { fixture.cleanup() }
      try fixture.session.openCustody()
      fixture.session.ready = true
      fixture.session.phase = .capturing
      fixture.session.location.startUpdatesIfAuthorized()
      fixture.session.location.stop()
      fixture.session.capture()
      XCTAssertEqual(fixture.manager.starts, 2)
      XCTAssertEqual(fixture.manager.requests, 0)
      XCTAssertNil(fixture.session.operation)
      XCTAssertNil(fixture.session.activeCaptureAttempt)
      XCTAssertEqual(fixture.session.issue, .locationRequired)
      XCTAssertEqual(fixture.session.location.status, .awaitingFix)
      try await fixture.session.erase()
    }

    func testStopThenLateGrantCannotResurrectStartup() async throws {
      let fixture = try LocationSessionFixture()
      defer { fixture.cleanup() }
      fixture.session.start()
      await fixture.manager.waitForRequest()
      let startup = fixture.session.operation
      fixture.session.stop()
      fixture.manager.resolve(.authorizedWhenInUse)
      await startup?.value
      XCTAssertNil(fixture.session.store)
      XCTAssertNil(fixture.session.recordingJournal)
      XCTAssertFalse(fixture.session.ready)
      XCTAssertEqual(fixture.session.phase, .inactive)
      XCTAssertEqual(fixture.manager.starts, 0)
    }
  }

  @MainActor
  private struct LocationSessionFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let manager: LocationManagerStub
    let session: CaptureSession
    init(_ status: CLAuthorizationStatus = .notDetermined) throws {
      manager = LocationManagerStub(status)
      let now: @Sendable () -> Date = { Date(timeIntervalSince1970: 123) }
      session = CaptureSession(
        configuration: .init(
          notifications: NotificationCenter(),
          custody: try .init(applicationID: "synthetic.capture-sdk.fixture",
            directory: directory, keychainService: "synthetic." + UUID().uuidString,
            keychainAccount: "location-tests", accessGroup: "TEST.capture-sdk.fixture"),
          signing: try .testing(applicationID: "synthetic.capture-sdk.fixture", installationID: "synthetic-installation"),
          clock: .init(now: now, uptime: { ProcessInfo.processInfo.systemUptime }),
          consent: .permitted)).withFixtureCustody()
      session.location = CaptureSessionLocation(manager: manager, now: now)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
  }

  @MainActor
  private final class LocationManagerStub: CaptureSessionLocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var authorizationStatus: CLAuthorizationStatus
    var requests = 0
    var starts = 0
    var stops = 0
    private var requestWaiter: CheckedContinuation<Void, Never>?

    init(_ status: CLAuthorizationStatus = .notDetermined) { authorizationStatus = status }
    func requestWhenInUseAuthorization() {
      requests += 1
      requestWaiter?.resume()
      requestWaiter = nil
    }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
    func resolve(_ status: CLAuthorizationStatus) {
      authorizationStatus = status
      delegate?.locationManagerDidChangeAuthorization?(CLLocationManager())
    }
    func waitForRequest() async {
      if requests > 0 { return }
      await withCheckedContinuation { requestWaiter = $0 }
    }
  }

#endif
