import Combine
import CoreLocation
import Foundation

/// GPS source for vehicle speed and road-map matching.
final class VehicleSpeedMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let speedScaleKey = "xadas.gps.speedScale"
    static let speedOffsetKey = "xadas.gps.speedOffsetKPH"

    @Published private(set) var speedKPH: Double = 0
    @Published private(set) var rawSpeedKPH: Double = 0
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var latestLocation: CLLocation?
    @Published private(set) var courseDegrees: Double?

    private let manager = CLLocationManager()
    private var filteredRawSpeedKPH: Double = 0
    private var hasSpeedSample = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        UserDefaults.standard.register(defaults: [
            Self.speedScaleKey: 1.0,
            Self.speedOffsetKey: 0.0
        ])
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
            rawSpeedKPH = 0
            latestLocation = nil
        @unknown default:
            speedKPH = 0
            rawSpeedKPH = 0
            latestLocation = nil
        }
    }

    func stop() { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in self?.authorizationStatus = manager.authorizationStatus }
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
            filteredRawSpeedKPH = filteredRawSpeedKPH * 0.55 + bounded * 0.45
        } else {
            filteredRawSpeedKPH = bounded
            hasSpeedSample = true
        }

        let scale = min(max(UserDefaults.standard.double(forKey: Self.speedScaleKey), 0.85), 1.20)
        let offset = min(max(UserDefaults.standard.double(forKey: Self.speedOffsetKey), -15), 15)
        // Keep a true zero while stopped; applying a positive calibration offset
        // at standstill would break LVDA and stationary warning logic.
        let calibrated = filteredRawSpeedKPH < 1.0
            ? 0
            : min(max(filteredRawSpeedKPH * scale + offset, 0), 260)

        let course = location.course >= 0 ? location.course : nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rawSpeedKPH = self.filteredRawSpeedKPH
            self.speedKPH = calibrated
            self.latestLocation = location
            self.courseDegrees = course
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.speedKPH = 0
            self?.rawSpeedKPH = 0
        }
    }
}
