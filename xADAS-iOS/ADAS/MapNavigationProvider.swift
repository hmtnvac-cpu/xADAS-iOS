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
    @Published private(set) var status = "NAV • OSM READY"
    @Published private(set) var searchResults: [IvySearchResult] = []
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var destinationName: String?

    private var latestLocation: CLLocation?
    private var lastRouteRequestAt: TimeInterval = 0
    private var routeTask: URLSessionDataTask?
    private var searchTask: URLSessionDataTask?
    private let minimumRouteRefreshInterval: TimeInterval = 8
    private let userAgent = "IvyADAS/1.0 (iOS; personal navigation project)"
    private let clientID = "ivy-adas-ios"

    var isNavigating: Bool { destinationCoordinate != nil }

    func ingest(location: CLLocation) {
        latestLocation = location
        guard destinationCoordinate != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRouteRequestAt >= minimumRouteRefreshInterval else { return }
        lastRouteRequestAt = now
        requestRoute()
    }

    // Deliberately invoked only by an explicit Search/Return action in the UI.
    // Public Nominatim forbids client-side autocomplete.
    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchTask?.cancel()
            searchResults = []
            status = "NAV • OSM READY"
            return
        }

        var components = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "countrycodes", value: "vn"),
            URLQueryItem(name: "accept-language", value: "vi")
        ]
        guard let url = components?.url else { return }

        searchTask?.cancel()
        status = "NAV • SEARCHING OSM"
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("vi", forHTTPHeaderField: "Accept-Language")

        searchTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                DispatchQueue.main.async { self.status = "NAV • SEARCH ERROR" }
                return
            }
            do {
                let decoded = try JSONDecoder().decode([NominatimResult].self, from: data)
                let results = decoded.compactMap { item -> IvySearchResult? in
                    guard let lat = Double(item.lat), let lon = Double(item.lon) else { return nil }
                    let title = item.name?.isEmpty == false ? item.name! : item.display_name.components(separatedBy: ",").first ?? "Điểm đến"
                    return IvySearchResult(name: title, subtitle: item.display_name, coordinate: .init(latitude: lat, longitude: lon))
                }
                DispatchQueue.main.async {
                    self.searchResults = results
                    self.status = results.isEmpty ? "NAV • NO RESULT" : "NAV • OSM RESULTS"
                }
            } catch {
                DispatchQueue.main.async { self.status = "NAV • SEARCH PARSE ERROR" }
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
        status = "NAV • OSM READY"
    }

    private func requestRoute() {
        guard let origin = latestLocation?.coordinate, let destination = destinationCoordinate else {
            status = "NAV • WAIT GPS"
            return
        }

        let payload = ValhallaRouteRequest(
            locations: [
                .init(lat: origin.latitude, lon: origin.longitude),
                .init(lat: destination.latitude, lon: destination.longitude)
            ],
            costing: "auto",
            units: "kilometers",
            language: "vi-VN"
        )
        guard let url = URL(string: "https://valhalla1.openstreetmap.de/route"),
              let body = try? JSONEncoder().encode(payload) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-Id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        routeTask?.cancel()
        status = "NAV • ROUTING OSM"
        routeTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                DispatchQueue.main.async { self.status = "NAV • ROUTE ERROR" }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(ValhallaRouteResponse.self, from: data)
                guard let leg = decoded.trip.legs.first,
                      let maneuver = leg.maneuvers.first(where: { $0.type != 1 }) ?? leg.maneuvers.first else {
                    DispatchQueue.main.async { self.status = "NAV • NO ROUTE" }
                    return
                }
                let summary = IvyNavigationSummary(
                    instruction: maneuver.instruction,
                    modifier: nil,
                    maneuverDistanceMeters: maneuver.length * 1000,
                    remainingDistanceMeters: decoded.trip.summary.length * 1000,
                    remainingDurationSeconds: decoded.trip.summary.time,
                    destinationName: self.destinationName ?? "Điểm đến"
                )
                DispatchQueue.main.async {
                    self.summary = summary
                    self.status = "NAV • ACTIVE OSM"
                }
            } catch {
                DispatchQueue.main.async { self.status = "NAV • ROUTE PARSE ERROR" }
            }
        }
        routeTask?.resume()
    }
}

private struct NominatimResult: Decodable {
    let lat: String
    let lon: String
    let display_name: String
    let name: String?
}

private struct ValhallaRouteRequest: Encodable {
    struct Point: Encodable { let lat: Double; let lon: Double }
    let locations: [Point]
    let costing: String
    let units: String
    let language: String
}

private struct ValhallaRouteResponse: Decodable {
    let trip: Trip
    struct Trip: Decodable {
        let summary: Summary
        let legs: [Leg]
    }
    struct Summary: Decodable {
        let time: Double
        let length: Double
    }
    struct Leg: Decodable { let maneuvers: [Maneuver] }
    struct Maneuver: Decodable {
        let type: Int
        let instruction: String
        let length: Double
    }
}
