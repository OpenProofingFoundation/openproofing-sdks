#if os(iOS)
  import CoreLocation
  import Foundation
  import DocumentCaptureApple
  import DocumentSDK

  @MainActor
  protocol CaptureSessionLocationManaging: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
  }

  extension CLLocationManager: CaptureSessionLocationManaging {}

  /// Foreground authorization and fix acquisition have separate lifetimes.
  @MainActor
  public final class CaptureSessionLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager: any CaptureSessionLocationManaging
    private var active = false
    private var requestPending = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var latest: CLLocation?
    private var lastDiagnostic: CaptureSessionLocationDiagnostic?
    private let now: @Sendable () -> Date
    private let diagnostic: (CaptureSessionLocationDiagnostic) -> Void
    public private(set) var permissionStatus: CLAuthorizationStatus
    public private(set) var status: CaptureSessionLocationStatus = .inactive

    init(
      manager: any CaptureSessionLocationManaging, now: @escaping @Sendable () -> Date,
      diagnostic: @escaping (CaptureSessionLocationDiagnostic) -> Void = { _ in }
    ) {
      self.now = now
      self.manager = manager
      self.diagnostic = diagnostic
      permissionStatus = manager.authorizationStatus
      super.init()
      manager.delegate = self
    }

    public convenience init(now: @escaping @Sendable () -> Date) {
      let manager = CLLocationManager()
      manager.desiredAccuracy = kCLLocationAccuracyBest
      manager.distanceFilter = kCLDistanceFilterNone
      self.init(manager: manager, now: now)
    }

    /// Requests at most one system prompt; no camera or fix updates start here.
    func requestPermission() async -> Bool {
      guard !Task.isCancelled else { return false }
      refreshAuthorization()
      if permissionStatus != .notDetermined { return isAuthorized }
      let identifier = UUID()
      return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          guard !Task.isCancelled else {
            continuation.resume(returning: false)
            return
          }
          waiters[identifier] = continuation
          status = .authorizationRequired
          if !requestPending {
            requestPending = true
            record("permission_request")
            manager.requestWhenInUseAuthorization()
          }
        }
      } onCancel: {
        Task { @MainActor [weak self] in
          self?.waiters.removeValue(forKey: identifier)?.resume(returning: false)
        }
      }
    }

    /// Arming may collect fixes only after explicit authorization has completed.
    @discardableResult
    func startUpdatesIfAuthorized() -> Bool {
      refreshAuthorization()
      guard isAuthorized else { return false }
      active = true
      status = .awaitingFix
      manager.startUpdatingLocation()
      record("updates_started")
      return true
    }

    public func stop() {
      active = false
      latest = nil
      manager.stopUpdatingLocation()
      let pending = waiters.values
      waiters.removeAll()
      for waiter in pending { waiter.resume(returning: false) }
      record("stopped")
    }

    private var isAuthorized: Bool {
      permissionStatus == .authorizedAlways || permissionStatus == .authorizedWhenInUse
    }

    private func refreshAuthorization() {
      permissionStatus = manager.authorizationStatus
      switch permissionStatus {
      case .notDetermined:
        status = .authorizationRequired
      case .authorizedAlways, .authorizedWhenInUse:
        status = .awaitingFix
      case .denied:
        status = .denied
      case .restricted:
        status = .restricted
      @unknown default:
        status = .unavailable
      }
      if permissionStatus != .notDetermined {
        requestPending = false
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: isAuthorized) }
      }
      if !isAuthorized {
        latest = nil
        manager.stopUpdatingLocation()
      }
      record("authorization_readback")
    }

    public func assertion() -> CaptureLocationAssertion? {
      let now = now()
      guard active, isAuthorized else { return nil }
      guard let latest, let assertion = Self.assertion(from: latest, now: now) else {
        status = .awaitingFix
        return nil
      }
      return assertion
    }

    static func assertion(from location: CLLocation, now: Date) -> CaptureLocationAssertion? {
      let age = now.timeIntervalSince(location.timestamp)
      guard age.isFinite, (0...DocumentCaptureTuning.Location.maximumFixAgeSeconds).contains(age),
        location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0
      else { return nil }
      let hasAltitude =
        location.verticalAccuracy.isFinite && location.verticalAccuracy >= 0
        && location.altitude.isFinite
      let result = CaptureLocationAssertion(
        latitudeDegrees: location.coordinate.latitude,
        longitudeDegrees: location.coordinate.longitude,
        horizontalAccuracyMeters: location.horizontalAccuracy,
        altitudeMeters: hasAltitude ? location.altitude : nil,
        verticalAccuracyMeters: hasAltitude ? location.verticalAccuracy : nil,
        fixedAt: location.timestamp,
        source: location.sourceInformation?.isSimulatedBySoftware == true
          ? .hostSimulated : .hostDeviceLocationService)
      return result.wellFormed ? result : nil
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      refreshAuthorization()
      if active, isAuthorized { self.manager.startUpdatingLocation() }
    }

    public func locationManager(
      _ _: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
      guard active, isAuthorized else { return }
      latest =
        locations.filter { Self.assertion(from: $0, now: now()) != nil }
        .max(by: { $0.timestamp < $1.timestamp }) ?? latest
      if latest != nil { status = .ready }
    }

    public func locationManager(_ _: CLLocationManager, didFailWithError error: Error) {
      guard active, isAuthorized else { return }
      latest = nil
      status = .unavailable
      let code = (error as NSError).code
      record("fix_error_\(code)")
    }

    private func record(_ event: String) {
      let line = CaptureSessionLocationDiagnostic(
        event: event,
        permissionRawValue: Int(permissionStatus.rawValue), active: active)
      guard line != lastDiagnostic else { return }
      lastDiagnostic = line
      diagnostic(line)
    }
  }

  public enum CaptureSessionLocationStatus: String, Sendable {
    case inactive, authorizationRequired, awaitingFix, denied, restricted, unavailable, ready
  }
  public struct CaptureSessionLocationDiagnostic: Equatable, Sendable {
    public let event: String
    public let permissionRawValue: Int
    public let active: Bool
  }
#endif
