#if os(iOS)
  import ARKit
  import AVFoundation
  import XCTest
  @testable import BiometricCapture

  @MainActor
  final class NativeSelfieSessionConsentTests: XCTestCase {
    func testUnsupportedHardwareNeverAsksPermissionOrStartsCamera() {
      let h = NativeHarness()
      h.supported = false
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      XCTAssertEqual(h.session.state, .failed(.init(reason: .unavailable)))
      XCTAssertEqual(h.authorizationQueries, 0)
      XCTAssertEqual(h.runs, 0)
      XCTAssertFalse(h.session.retry())
    }
    func testVisibilityAndOSPermissionCannotSubstituteForConsent() {
      let h = NativeHarness()
      h.session.setActive(true)
      XCTAssertEqual(h.session.state, .awaitingConsent)
      XCTAssertEqual(h.session.consent, .withheld)
      XCTAssertEqual(h.authorizationQueries, 0)
      XCTAssertEqual(h.runs, 0)
      h.session.capture()
      h.session.setConsent(.permitted)
      XCTAssertEqual(h.session.state, .starting)
      XCTAssertEqual(h.runs, 1)
      h.session.setActive(true)
      XCTAssertEqual(h.runs, 1)
      h.session.setConsent(.withheld)
      XCTAssertEqual(h.session.state, .awaitingConsent)
      XCTAssertGreaterThan(h.pauses, 0)
      XCTAssertFalse(h.session.retry())
      h.session.setConsent(.permitted)
      XCTAssertEqual(h.runs, 2)
      h.session.stop()
    }

    func testCameraDenialAndRestrictionRemainSeparateFromConsent() {
      for (status, reason) in [
        (AVAuthorizationStatus.denied, SelfieCameraFailure.Reason.cameraPermissionDenied),
        (.restricted, .cameraPermissionRestricted),
      ] {
        let h = NativeHarness()
        h.authorization = status
        h.session.setConsent(.permitted)
        h.session.setActive(true)
        XCTAssertEqual(h.session.state, .failed(.init(reason: reason)))
        XCTAssertEqual(h.session.consent, .permitted)
        XCTAssertEqual(h.runs, 0)
        XCTAssertFalse(h.session.retry())
        h.authorization = .authorized
        XCTAssertTrue(h.session.retry())
        XCTAssertEqual(h.runs, 1)
        h.session.stop()
      }
    }

    func testWithdrawingConsentFencesLateOSPermissionGrant() async {
      let h = NativeHarness()
      h.authorization = .notDetermined
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      await eventually { h.permissionRequests == 1 }
      XCTAssertEqual(h.session.state, .requestingPermission)
      h.session.setConsent(.withheld)
      h.authorization = .authorized
      h.finishPermission(true)
      await eventually { h.permissionCallbackReturned }
      XCTAssertEqual(h.session.state, .awaitingConsent)
      XCTAssertEqual(h.runs, 0)
      h.session.setConsent(.permitted)
      XCTAssertEqual(h.runs, 1)
      h.session.stop()
    }

    func testRevocationAndRegrantDoNotMultiplyBlockedPermissionRequests() async {
      let h = NativeHarness()
      h.authorization = .notDetermined
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      await eventually { h.permissionRequests == 1 }
      for _ in 0..<5 {
        h.session.setConsent(.withheld)
        h.session.setConsent(.permitted)
      }
      XCTAssertEqual(h.permissionRequests, 1)
      XCTAssertEqual(h.runs, 0)
      h.authorization = .authorized
      h.finishPermission(true)
      await eventually { h.runs == 1 }
      XCTAssertEqual(h.permissionRequests, 1)
      h.session.stop()
    }

    func testStopFencesLatePermissionAndRequiresNewActiveIntent() async {
      let h = NativeHarness()
      h.authorization = .notDetermined
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      await eventually { h.permissionRequests == 1 }
      h.session.stop()
      h.authorization = .authorized
      h.finishPermission(true)
      await eventually { h.permissionCallbackReturned }
      XCTAssertEqual(h.session.state, .stopped)
      XCTAssertEqual(h.runs, 0)
      h.session.setActive(true)
      XCTAssertEqual(h.runs, 1)
      h.session.stop()
    }

    func testNoFrameFailureIsRecoverableOnlyByExplicitRetry() {
      let h = NativeHarness()
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      h.now = 11
      h.coordinator.checkTimeouts()
      XCTAssertEqual(h.session.state, .failed(.init(reason: .noFrames)))
      h.session.setActive(true)
      XCTAssertEqual(h.runs, 1)
      XCTAssertTrue(h.session.retry())
      XCTAssertEqual(h.runs, 2)
      XCTAssertEqual(h.session.state, .starting)
      h.session.stop()
    }

    func testReentrantConsentWithdrawalAtStartingPreventsCameraRun() {
      let h = NativeHarness()
      h.session.onState = { state in
        if state == .starting { h.session.setConsent(.withheld) }
      }
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      XCTAssertEqual(h.session.state, .awaitingConsent)
      XCTAssertEqual(h.runs, 0)
    }

    func testReentrantStopAtStartingPreventsCameraRun() {
      let h = NativeHarness()
      h.session.onState = { state in
        if state == .starting { h.session.stop() }
      }
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      XCTAssertEqual(h.session.state, .stopped)
      XCTAssertEqual(h.runs, 0)
    }

    func testReentrantWithdrawalAtPermissionStatePreventsOSRequest() async {
      let h = NativeHarness()
      h.authorization = .notDetermined
      h.session.onState = { state in
        if state == .requestingPermission { h.session.setConsent(.withheld) }
      }
      h.session.setConsent(.permitted)
      h.session.setActive(true)
      await Task.yield()
      XCTAssertEqual(h.session.state, .awaitingConsent)
      XCTAssertEqual(h.permissionRequests, 0)
      XCTAssertEqual(h.runs, 0)
    }

    private func eventually(
      file: StaticString = #filePath, line: UInt = #line,
      _ predicate: @MainActor () -> Bool
    ) async {
      for _ in 0..<100 {
        if predicate() { return }
        try? await Task.sleep(for: .milliseconds(1))
      }
      XCTFail("Expected native lifecycle event", file: file, line: line)
    }
  }

  @MainActor
  private final class NativeHarness {
    var now = 1.0
    var supported = true
    var runs = 0
    var pauses = 0
    var authorizationQueries = 0
    var permissionRequests = 0
    var permissionCallbackReturned = false
    var authorization = AVAuthorizationStatus.authorized
    private var permissionContinuation: CheckedContinuation<Bool, Never>?
    lazy var coordinator = SelfieCaptureCoordinator(
      policy: .init(),
      analyze: { _ in .init(faceCount: 0, quality: nil, faceBox: nil, revision: 3, elapsed: 0) },
      clock: { [unowned self] in now })
    lazy var session = NativeSelfieSession(
      coordinator: coordinator,
      camera: .init(
        isSupported: { [unowned self] in supported },
        authorizationStatus: { [unowned self] in
          authorizationQueries += 1
          return authorization
        },
        requestPermission: { [unowned self] in
          permissionRequests += 1
          let granted = await withCheckedContinuation { permissionContinuation = $0 }
          permissionCallbackReturned = true
          return granted
        },
        run: { [unowned self] _ in runs += 1 },
        pause: { [unowned self] _ in pauses += 1 }))

    func finishPermission(_ granted: Bool) {
      permissionContinuation?.resume(returning: granted)
      permissionContinuation = nil
    }
  }
#endif
