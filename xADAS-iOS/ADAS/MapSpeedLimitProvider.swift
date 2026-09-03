import Combine
import CoreLocation
import Foundation

/// Uses a short GPS trace with Mapbox Map Matching and requests `maxspeed`
/// annotations for the road segment currently occupied by the vehicle.
final class MapSpeedLimitProvider: ObservableObject {
    @Published private(set) var speedLimitKPH: Int?
    @Published private(set) var status = "MAP LIMIT • READY"
    @Published private(set) var lastUpdatedAt: Date?

    private var trace: [CLLocation] = []
    private var lastRequestAt: TimeInterval = 0
    private var task: URLSessionDataTask?

    private let minimumRequestInterval: TimeInterval = 4.0
    private let maximumTracePoints = 8

    private var token: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MapboxAccessToken") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "__MAPBOX_TOKEN__" else { return nil }
        return trimmed
    }

    func ingest(location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 35 else {
            status = "MAP LIMIT • GPS WEAK"
            return
        }

        if let last = trace.last, location.distance(from: last) < 2.0 {
            return
        }

        trace.append(location)
        if trace.count > maximumTracePoints {
            trace.removeFirst(trace.count - maximumTracePoints)
        }

        guard trace.count >= 3 else {
            status = "MAP LIMIT • GPS TRACE"
            return
        }

        guard token != nil else {
            status = "MAP LIMIT • NO TOKEN"
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRequestAt >= minimumRequestInterval else { return }
        lastRequestAt = now
        requestMatch()
    }

    private func requestMatch() {
        guard let token else { return }
        let points = trace.suffix(maximumTracePoints)
        let coordinates = points.map {
            String(format: "%.6f,%.6f", $0.coordinate.longitude, $0.coordinate.latitude)
        }.joined(separator: ";")

        var components = URLComponents(string: "https://api.mapbox.com/matching/v5/mapbox/driving/\(coordinates).json")
        components?.queryItems = [
            URLQueryItem(name: "annotations", value: "maxspeed"),
            URLQueryItem(name: "overview", value: "full"),
            URLQueryItem(name: "geometries", value: "geojson"),
            URLQueryItem(name: "access_token", value: token)
        ]
        guard let url = components?.url else {
            status = "MAP LIMIT • URL ERROR"
            return
        }

        task?.cancel()
        status = "MAP LIMIT • MATCHING"
        task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async { self.status = "MAP LIMIT • NET \(error.localizedDescription)" }
                return
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                DispatchQueue.main.async { self.status = "MAP LIMIT • HTTP ERROR" }
                return
            }

            do {
                let decoded = try JSONDecoder().decode(MapMatchingResponse.self, from: data)
                let values = decoded.matchings
                    .flatMap(\.legs)
                    .compactMap(\.annotation)
                    .flatMap(\.maxspeed)
                    .compactMap(Self.kph(from:))

                DispatchQueue.main.async {
                    self.speedLimitKPH = values.last
                    self.lastUpdatedAt = Date()
                    self.status = values.last.map { "MAP LIMIT • \($0)" } ?? "MAP LIMIT • UNKNOWN"
                }
            } catch {
                DispatchQueue.main.async { self.status = "MAP LIMIT • PARSE ERROR" }
            }
        }
        task?.resume()
    }

    private static func kph(from maxspeed: MapMatchingResponse.MaxSpeed) -> Int? {
        guard let speed = maxspeed.speed, let unit = maxspeed.unit else { return nil }
        if unit.lowercased() == "mph" {
            return Int((Double(speed) * 1.609344).rounded())
        }
        return speed
    }
}

private struct MapMatchingResponse: Decodable {
    let matchings: [Matching]

    struct Matching: Decodable {
        let legs: [Leg]
    }

    struct Leg: Decodable {
        let annotation: Annotation?
    }

    struct Annotation: Decodable {
        let maxspeed: [MaxSpeed]
    }

    struct MaxSpeed: Decodable {
        let speed: Int?
        let unit: String?
        let unknown: Bool?
        let none: Bool?
    }
}
