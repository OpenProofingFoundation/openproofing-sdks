import Foundation
import CoreLocation
import KenshikiMotion

/// OS permission/sensor adapter. It has no verification or identity-decision authority.
@MainActor final class WorkflowSensorHost: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let motion = PulseCeremonyMotionWitness(ceremony: .faceMatch)
    private let permission = PulseMotionPermission()
    private let manager = CLLocationManager()
    private var active = false
    private var generation = UUID()
    private var changed: (@MainActor () -> Void)?
    private var fix: SavedWorkflowLocation.Fix?
    private var errorCode: Int?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    var port: WorkflowSensorPort {
        WorkflowSensorPort(start: { [self] in start(changed: $0) }, stop: { [self] in stop() },
            motion: { [self] in motion.snapshot(endingAtUptime: ProcessInfo.processInfo.systemUptime).map(SavedWorkflowMotion.init) },
            motionPermission: { [self] in permission.status.rawValue }, location: { [self] in location() })
    }

    private func start(changed: @escaping @MainActor () -> Void) {
        stop()
        active = true
        self.changed = changed
        let token = generation
        permission.request { [weak self] status in
            guard let self, self.active, self.generation == token else { return }
            if status == .authorized { self.motion.start() }
            if status != .requesting {
                if self.manager.authorizationStatus == .notDetermined { self.manager.requestWhenInUseAuthorization() }
                self.updateLocationAcquisition()
            }
            self.changed?()
        }
        updateLocationAcquisition()
    }

    private func stop() {
        generation = UUID(); active = false; changed = nil
        permission.cancel(); _ = motion.stop(); manager.stopUpdatingLocation()
        fix = nil; errorCode = nil
    }

    private func updateLocationAcquisition() {
        guard active else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.startUpdatingLocation()
        default: manager.stopUpdatingLocation(); fix = nil
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard active else { return }
        updateLocationAcquisition()
        changed?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let value = locations.last, value.horizontalAccuracy >= 0 else { return }
        let altitude = value.verticalAccuracy >= 0 ? value.altitude : nil
        fix = SavedWorkflowLocation.Fix(timestamp: value.timestamp,
            latitude: value.coordinate.latitude, longitude: value.coordinate.longitude,
            horizontalAccuracyMeters: value.horizontalAccuracy,
            altitudeMeters: altitude, verticalAccuracyMeters: value.verticalAccuracy >= 0 ? value.verticalAccuracy : nil,
            simulatedBySoftware: value.sourceInformation?.isSimulatedBySoftware,
            producedByAccessory: value.sourceInformation?.isProducedByAccessory)
        errorCode = nil
        changed?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard active else { return }
        errorCode = (error as NSError).code
        changed?()
    }

    private func location() -> SavedWorkflowLocation {
        let state: SavedWorkflowLocation.Permission
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: state = .authorized
        case .notDetermined: state = .notRequested
        case .denied: state = .denied
        case .restricted: state = .restricted
        @unknown default: state = .unavailable
        }
        let accuracy: SavedWorkflowLocation.Accuracy = state == .authorized
            ? (manager.accuracyAuthorization == .fullAccuracy ? .full : .reduced) : .unavailable
        return SavedWorkflowLocation(permission: state, accuracy: accuracy, observedAt: Date(),
            fix: state == .authorized ? fix : nil, providerErrorCode: errorCode)
    }
}
