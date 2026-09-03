import Combine
import CoreLocation
import Foundation

/// GPS speed source used only to gate experimental audible/haptic ADAS warnings.
/// Camera recognition continues to run while the vehicle is stationary.
final class VehicleSpeedMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var speedKPH: Double = 0
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    private let manager = CLLocationManager()
    private var filteredSpeedKPH: Double = 0
    private var hasSpeedSample = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            speedKPH = 0
        @unknown default:
            speedKPH = 0
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            self?.authorizationStatus = manager.authorizationStatus
        }
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= 50,
              location.speed >= 0 else { return }

        let rawKPH = location.speed * 3.6
        let bounded = min(max(rawKPH, 0), 250)

        // Light smoothing avoids GPS jitter around the 60 km/h activation point
        // while still reacting in roughly one update when entering highway speed.
        if hasSpeedSample {
            filteredSpeedKPH = filteredSpeedKPH * 0.65 + bounded * 0.35
        } else {
            filteredSpeedKPH = bounded
            hasSpeedSample = true
        }

        DispatchQueue.main.async { [weak self] in
            self?.speedKPH = self?.filteredSpeedKPH ?? 0
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No valid GPS speed means warnings remain gated off for safety.
        DispatchQueue.main.async { [weak self] in
            self?.speedKPH = 0
        }
    }
}
