import Combine
import CoreLocation
import Foundation

struct IvyNavigationSummary: Equatable {
    var instruction: String
    var modifier: String?
    var maneuverDistanceMeters: Double
    var remainingDistanceMeters: Double
    var remainingDurationSeconds: Double
    var destinationName: String
}

struct IvySearchResult: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D

    static func == (lhs: IvySearchResult, rhs: IvySearchResult) -> Bool {
        lhs.name == rhs.name && lhs.subtitle == rhs.subtitle && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

final class MapNavigationProvider: ObservableObject {
    @Published private(set) var summary: IvyNavigationSummary?
    @Published private(set) var status = "NAV • READY"
    @Published private(set) var searchResults: [IvySearchResult] = []
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var destinationName: String?

    private var latestLocation: CLLocation?
    private var lastRouteRequestAt: TimeInterval = 0
    private var routeTask: URLSessionDataTask?
    private var searchTask: URLSessionDataTask?
    private let minimumRouteRefreshInterval: TimeInterval = 8

    private var token: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MapboxAccessToken") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "__MAPBOX_TOKEN__" else { return nil }
        return trimmed
    }

    var isNavigating: Bool { destinationCoordinate != nil }

    func ingest(location: CLLocation) {
        latestLocation = location
        guard destinationCoordinate != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRouteRequestAt >= minimumRouteRefreshInterval else { return }
        lastRouteRequestAt = now
        requestRoute()
    }

    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchTask?.cancel()
            searchResults = []
            return
        }
        guard let token else {
            status = "NAV • NO TOKEN"
            return
        }

        var components = URLComponents(string: "https://api.mapbox.com/search/geocode/v6/forward")
        var items = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "language", value: "vi"),
            URLQueryItem(name: "country", value: "vn"),
            URLQueryItem(name: "access_token", value: token)
        ]
        if let location = latestLocation {
            items.append(URLQueryItem(name: "proximity", value: "\(location.coordinate.longitude),\(location.coordinate.latitude)"))
        }
        components?.queryItems = items
        guard let url = components?.url else { return }

        searchTask?.cancel()
        status = "NAV • SEARCHING"
        searchTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                DispatchQueue.main.async { self.status = "NAV • SEARCH ERROR" }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(GeocodeResponse.self, from: data)
                let results = decoded.features.compactMap { feature -> IvySearchResult? in
                    guard feature.geometry.coordinates.count >= 2 else { return nil }
                    let coordinate = CLLocationCoordinate2D(latitude: feature.geometry.coordinates[1], longitude: feature.geometry.coordinates[0])
                    let title = feature.properties.name ?? feature.properties.full_address ?? "Điểm đến"
                    let subtitle = feature.properties.full_address ?? feature.properties.place_formatted ?? ""
                    return IvySearchResult(name: title, subtitle: subtitle, coordinate: coordinate)
                }
                DispatchQueue.main.async {
                    self.searchResults = results
                    self.status = results.isEmpty ? "NAV • NO RESULT" : "NAV • RESULTS"
                }
            } catch {
                DispatchQueue.main.async { self.status = "NAV • PARSE ERROR" }
            }
        }
        searchTask?.resume()
    }

    func startNavigation(to result: IvySearchResult) {
        destinationCoordinate = result.coordinate
        destinationName = result.name
        searchResults = []
        lastRouteRequestAt = 0
        requestRoute()
    }

    func stopNavigation() {
        routeTask?.cancel()
        destinationCoordinate = nil
        destinationName = nil
        summary = nil
        status = "NAV • READY"
    }

    private func requestRoute() {
        guard let token, let origin = latestLocation?.coordinate, let destination = destinationCoordinate else {
            if token == nil { status = "NAV • NO TOKEN" }
            return
        }

        let coords = "\(origin.longitude),\(origin.latitude);\(destination.longitude),\(destination.latitude)"
        var components = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/\(coords)")
        components?.queryItems = [
            URLQueryItem(name: "steps", value: "true"),
            URLQueryItem(name: "banner_instructions", value: "true"),
            URLQueryItem(name: "language", value: "vi"),
            URLQueryItem(name: "overview", value: "false"),
            URLQueryItem(name: "alternatives", value: "false"),
            URLQueryItem(name: "access_token", value: token)
        ]
        guard let url = components?.url else { return }

        routeTask?.cancel()
        status = "NAV • ROUTING"
        routeTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                DispatchQueue.main.async { self.status = "NAV • ROUTE ERROR" }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(DirectionsResponse.self, from: data)
                guard let route = decoded.routes.first,
                      let leg = route.legs.first,
                      let step = leg.steps.first(where: { $0.maneuver.type != "depart" }) ?? leg.steps.first else {
                    DispatchQueue.main.async { self.status = "NAV • NO ROUTE" }
                    return
                }
                let summary = IvyNavigationSummary(
                    instruction: step.maneuver.instruction,
                    modifier: step.maneuver.modifier,
                    maneuverDistanceMeters: step.distance,
                    remainingDistanceMeters: route.distance,
                    remainingDurationSeconds: route.duration,
                    destinationName: self.destinationName ?? "Điểm đến"
                )
                DispatchQueue.main.async {
                    self.summary = summary
                    self.status = "NAV • ACTIVE"
                }
            } catch {
                DispatchQueue.main.async { self.status = "NAV • PARSE ERROR" }
            }
        }
        routeTask?.resume()
    }
}

private struct GeocodeResponse: Decodable {
    let features: [Feature]
    struct Feature: Decodable {
        let properties: Properties
        let geometry: Geometry
    }
    struct Properties: Decodable {
        let name: String?
        let full_address: String?
        let place_formatted: String?
    }
    struct Geometry: Decodable {
        let coordinates: [Double]
    }
}

private struct DirectionsResponse: Decodable {
    let routes: [Route]
    struct Route: Decodable {
        let distance: Double
        let duration: Double
        let legs: [Leg]
    }
    struct Leg: Decodable {
        let steps: [Step]
    }
    struct Step: Decodable {
        let distance: Double
        let duration: Double
        let maneuver: Maneuver
    }
    struct Maneuver: Decodable {
        let instruction: String
        let modifier: String?
        let type: String
    }
}
