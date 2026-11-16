import Foundation
import CoreLocation

enum LocationError: LocalizedError {
    case notAuthorized
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Location is off. When parked, open WildPath on your phone and allow location."
        case .timedOut:
            return "Couldn't get your location. Try again in a moment."
        }
    }
}

/// Keeps a fresh GPS fix while the phone app or CarPlay is on screen, so a tap
/// saves the spot instantly instead of waiting for GPS.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    static let shared = LocationProvider()

    @Published private(set) var authorization: CLAuthorizationStatus
    /// Every new GPS fix. The driving view and hotspot warnings listen to this.
    @Published private(set) var lastLocation: CLLocation?

    private let manager = CLLocationManager()
    private var waiters: [UUID: CheckedContinuation<CLLocation, Error>] = [:]
    private var phoneActive = false
    private var carPlayActive = false
    private var driving = false

    private override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func setPhoneActive(_ active: Bool) {
        phoneActive = active
        updateTracking()
    }

    func setCarPlayActive(_ active: Bool) {
        carPlayActive = active
        updateTracking()
    }

    /// While a drive is on, keep GPS running even when another app (such as
    /// Google Maps) is in front, so warnings and camera reports keep working.
    /// iOS shows the blue location pill while this is on.
    func setDriving(_ active: Bool) {
        driving = active
        manager.allowsBackgroundLocationUpdates = active
        manager.showsBackgroundLocationIndicator = active
        manager.pausesLocationUpdatesAutomatically = !active
        updateTracking()
    }

    /// Returns a recent, accurate fix. A car at 55 mph covers about 25 m per
    /// second, so anything older than a few seconds would put the pin far off.
    func currentLocation(maxAge: TimeInterval = 5, timeout: Duration = .seconds(10)) async throws -> CLLocation {
        if let location = lastLocation, isUsable(location, maxAge: maxAge) {
            return location
        }
        guard isAuthorized else { throw LocationError.notAuthorized }

        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            manager.requestLocation()
            Task {
                try? await Task.sleep(for: timeout)
                self.resumeWaiter(id, with: .failure(LocationError.timedOut))
            }
        }
    }

    private func isUsable(_ location: CLLocation, maxAge: TimeInterval) -> Bool {
        -location.timestamp.timeIntervalSinceNow <= maxAge
            && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= 100
    }

    private func updateTracking() {
        if (phoneActive || carPlayActive || driving) && isAuthorized {
            manager.startUpdatingLocation()
        } else {
            manager.stopUpdatingLocation()
        }
    }

    private func resumeWaiter(_ id: UUID, with result: Result<CLLocation, Error>) {
        waiters.removeValue(forKey: id)?.resume(with: result)
    }

    private func resumeAllWaiters(with result: Result<CLLocation, Error>) {
        let pending = waiters
        waiters.removeAll()
        pending.values.forEach { $0.resume(with: result) }
    }

    fileprivate func handle(location: CLLocation) {
        lastLocation = location
        resumeAllWaiters(with: .success(location))
    }

    fileprivate func handle(error: Error) {
        resumeAllWaiters(with: .failure(error))
    }

    fileprivate func handle(authorization status: CLAuthorizationStatus) {
        authorization = status
        updateTracking()
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in self.handle(location: location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.handle(error: error) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.handle(authorization: status) }
    }
}
