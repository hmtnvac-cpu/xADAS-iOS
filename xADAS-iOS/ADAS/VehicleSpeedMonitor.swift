import Combine
import CoreLocation
import Foundation

/// GPS source for vehicle speed and road-map matching.
final class VehicleSpeedMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var speedKPH: Double = 0
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var courseDegrees: Double?

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
            latestLocation = nil
        @unknown default:
            speedKPH = 0
            latestLocation = nil
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
              location.horizontalAccuracy <= 50 else { return }

        let rawKPH = location.speed >= 0 ? location.speed * 3.6 : 0
        let bounded = min(max(rawKPH, 0), 250)

        if hasSpeedSample {
            filteredSpeedKPH = filteredSpeedKPH * 0.65 + bounded * 0.35
        } else {
            filteredSpeedKPH = bounded
            hasSpeedSample = true
        }

        let course = location.course >= 0 ? location.course : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speedKPH = self.filteredSpeedKPH
            self.latestLocation = location
            self.courseDegrees = course
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.speedKPH = 0
        }
    }
}
