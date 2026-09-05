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
    @Published private(set) var status = "NAV • GRAPHHOPPER READY"
    @Published private(set) var searchResults: [IvySearchResult] = []
    @Published private(set) var destinationCoordinate: CLLocationCoordinate2D?
    @Published private(set) var destinationName: String?

    private var latestLocation: CLLocation?
    private var routeTask: URLSessionDataTask?
    private var searchTask: URLSessionDataTask?
    private var lastRerouteAt: TimeInterval = 0
    private var usingGraphHopperRoute = false
    private var graphHopperPoints: [CLLocationCoordinate2D] = []
    private var graphHopperInstructions: [GraphHopperRouteResponse.Instruction] = []
    private var graphHopperRouteDistance: Double = 0
    private var graphHopperRouteTime: Double = 0
    private let minimumRerouteInterval: TimeInterval = 15
    private let offRouteDistanceMeters: CLLocationDistance = 80
    private let userAgent = "IvyADAS/1.0 (iOS; personal navigation project)"
    private let clientID = "ivy-adas-ios"

    private var graphHopperAPIKey: String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "GraphHopperAPIKey") as? String,
              !key.isEmpty,
              !key.hasPrefix("__") else { return nil }
        return key
    }

    var isNavigating: Bool { destinationCoordinate != nil }

    func ingest(location: CLLocation) {
        latestLocation = location
        guard destinationCoordinate != nil else { return }

        if usingGraphHopperRoute, !graphHopperPoints.isEmpty {
            updateGraphHopperProgress(location: location)
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRerouteAt >= minimumRerouteInterval else { return }
        lastRerouteAt = now
        requestRoute()
    }

    // Deliberately invoked only by an explicit Search/Return action in the UI.
    // Public Nominatim forbids client-side autocomplete.
    func search(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchTask?.cancel()
            searchResults = []
            status = "NAV • READY"
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
        startNavigation(coordinate: result.coordinate, name: result.name)
    }

    func startNavigation(coordinate: CLLocationCoordinate2D, name: String) {
        destinationCoordinate = coordinate
        destinationName = name
        searchResults = []
        clearCachedRoute()
        lastRerouteAt = ProcessInfo.processInfo.systemUptime
        requestRoute()
    }

    func importExternalShare(url: URL) {
        let sharedURL: URL
        if url.scheme?.lowercased() == "ivy",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
           let decoded = URL(string: raw) {
            sharedURL = decoded
        } else {
            sharedURL = url
        }

        status = "NAV • READING SHARED PLACE"
        if let imported = extractDestination(from: sharedURL) {
            startNavigation(coordinate: imported.coordinate, name: imported.name)
            return
        }

        guard sharedURL.scheme == "http" || sharedURL.scheme == "https" else {
            status = "NAV • SHARE NOT SUPPORTED"
            return
        }

        var request = URLRequest(url: sharedURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            guard error == nil, let resolvedURL = response?.url else {
                DispatchQueue.main.async { self.status = "NAV • SHARE ERROR" }
                return
            }
            DispatchQueue.main.async {
                if let imported = self.extractDestination(from: resolvedURL) {
                    self.startNavigation(coordinate: imported.coordinate, name: imported.name)
                } else {
                    self.status = "NAV • PLACE NOT FOUND"
                }
            }
        }.resume()
    }

    func stopNavigation() {
        routeTask?.cancel()
        destinationCoordinate = nil
        destinationName = nil
        summary = nil
        clearCachedRoute()
        status = "NAV • GRAPHHOPPER READY"
    }

    private func clearCachedRoute() {
        usingGraphHopperRoute = false
        graphHopperPoints = []
        graphHopperInstructions = []
        graphHopperRouteDistance = 0
        graphHopperRouteTime = 0
    }

    private func requestRoute() {
        guard let origin = latestLocation?.coordinate, let destination = destinationCoordinate else {
            status = "NAV • WAIT GPS"
            return
        }
        if let key = graphHopperAPIKey {
            requestGraphHopperRoute(origin: origin, destination: destination, key: key)
        } else {
            requestValhallaRoute(origin: origin, destination: destination)
        }
    }

    private func requestGraphHopperRoute(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D, key: String) {
        var components = URLComponents(string: "https://graphhopper.com/api/1/route")
        components?.queryItems = [
            URLQueryItem(name: "point", value: "\(origin.latitude),\(origin.longitude)"),
            URLQueryItem(name: "point", value: "\(destination.latitude),\(destination.longitude)"),
            URLQueryItem(name: "profile", value: "car"),
            URLQueryItem(name: "locale", value: "vi"),
            URLQueryItem(name: "instructions", value: "true"),
            URLQueryItem(name: "calc_points", value: "true"),
            URLQueryItem(name: "points_encoded", value: "false"),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components?.url else { return }

        routeTask?.cancel()
        status = "NAV • ROUTING GRAPHHOPPER"
        routeTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                DispatchQueue.main.async {
                    self.status = "NAV • GRAPHHOPPER FALLBACK"
                    self.requestValhallaRoute(origin: origin, destination: destination)
                }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(GraphHopperRouteResponse.self, from: data)
                guard let path = decoded.paths.first, !path.points.coordinates.isEmpty else {
                    DispatchQueue.main.async { self.requestValhallaRoute(origin: origin, destination: destination) }
                    return
                }
                let points = path.points.coordinates.compactMap { pair -> CLLocationCoordinate2D? in
                    guard pair.count >= 2 else { return nil }
                    return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
                }
                DispatchQueue.main.async {
                    self.usingGraphHopperRoute = true
                    self.graphHopperPoints = points
                    self.graphHopperInstructions = path.instructions ?? []
                    self.graphHopperRouteDistance = path.distance
                    self.graphHopperRouteTime = Double(path.time) / 1000.0
                    self.status = "NAV • ACTIVE GRAPHHOPPER"
                    if let location = self.latestLocation { self.updateGraphHopperProgress(location: location) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.status = "NAV • GRAPHHOPPER FALLBACK"
                    self.requestValhallaRoute(origin: origin, destination: destination)
                }
            }
        }
        routeTask?.resume()
    }

    private func updateGraphHopperProgress(location: CLLocation) {
        guard !graphHopperPoints.isEmpty else { return }
        var nearestIndex = 0
        var nearestDistance = CLLocationDistance.greatestFiniteMagnitude
        for (index, point) in graphHopperPoints.enumerated() {
            let d = location.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            if d < nearestDistance {
                nearestDistance = d
                nearestIndex = index
            }
        }

        if nearestDistance > offRouteDistanceMeters {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastRerouteAt >= minimumRerouteInterval {
                lastRerouteAt = now
                clearCachedRoute()
                requestRoute()
            }
            return
        }

        let instruction = graphHopperInstructions.first(where: { ($0.interval?.last ?? Int.max) >= nearestIndex && $0.sign != 4 })
            ?? graphHopperInstructions.last
        let instructionEnd = min(instruction?.interval?.last ?? nearestIndex, graphHopperPoints.count - 1)
        let maneuverDistance = routeDistance(from: nearestIndex, through: instructionEnd)
        let remainingDistance = routeDistance(from: nearestIndex, through: graphHopperPoints.count - 1)
        let duration = graphHopperRouteDistance > 1 ? graphHopperRouteTime * remainingDistance / graphHopperRouteDistance : graphHopperRouteTime

        summary = IvyNavigationSummary(
            instruction: instruction?.text ?? "Tiếp tục theo tuyến đường",
            modifier: modifier(for: instruction?.sign),
            maneuverDistanceMeters: maneuverDistance,
            remainingDistanceMeters: remainingDistance,
            remainingDurationSeconds: max(0, duration),
            destinationName: destinationName ?? "Điểm đến"
        )
        status = "NAV • ACTIVE GRAPHHOPPER"
    }

    private func routeDistance(from start: Int, through end: Int) -> Double {
        guard start < end, start >= 0, end < graphHopperPoints.count else { return 0 }
        var total: Double = 0
        for index in start..<end {
            let a = graphHopperPoints[index]
            let b = graphHopperPoints[index + 1]
            total += CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        return total
    }

    private func modifier(for sign: Int?) -> String? {
        guard let sign else { return nil }
        if [-3, -2, -1, -7].contains(sign) { return "left" }
        if [1, 2, 3, 7].contains(sign) { return "right" }
        if sign == 6 { return "roundabout" }
        if sign == 8 { return "uturn" }
        return "straight"
    }

    private func requestValhallaRoute(origin: CLLocationCoordinate2D, destination: CLLocationCoordinate2D) {
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
        status = "NAV • ROUTING OSM FALLBACK"
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
                    self.status = "NAV • ACTIVE OSM FALLBACK"
                }
            } catch {
                DispatchQueue.main.async { self.status = "NAV • ROUTE PARSE ERROR" }
            }
        }
        routeTask?.resume()
    }

    private func extractDestination(from url: URL) -> (coordinate: CLLocationCoordinate2D, name: String)? {
        let decodedString = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if let coordinate = firstCoordinate(in: decodedString) {
            return (coordinate, destinationLabel(from: url))
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            for key in ["ll", "q", "query", "destination"] {
                if let value = components.queryItems?.first(where: { $0.name.lowercased() == key })?.value,
                   let coordinate = coordinateFromPair(value) {
                    return (coordinate, destinationLabel(from: url))
                }
            }
        }
        return nil
    }

    private func firstCoordinate(in text: String) -> CLLocationCoordinate2D? {
        let patterns = [
            "@(-?[0-9]+(?:\\.[0-9]+)?),(-?[0-9]+(?:\\.[0-9]+)?)",
            "!3d(-?[0-9]+(?:\\.[0-9]+)?)!4d(-?[0-9]+(?:\\.[0-9]+)?)",
            "(?:ll|q|query|destination)=(-?[0-9]+(?:\\.[0-9]+)?),(-?[0-9]+(?:\\.[0-9]+)?)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange), match.numberOfRanges >= 3,
                  let latRange = Range(match.range(at: 1), in: text),
                  let lonRange = Range(match.range(at: 2), in: text),
                  let lat = Double(text[latRange]), let lon = Double(text[lonRange]),
                  abs(lat) <= 90, abs(lon) <= 180 else { continue }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    private func coordinateFromPair(_ value: String) -> CLLocationCoordinate2D? {
        let parts = value.replacingOccurrences(of: " ", with: "").split(separator: ",")
        guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]), abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func destinationLabel(from url: URL) -> String {
        let parts = url.pathComponents
        if let placeIndex = parts.firstIndex(where: { $0.lowercased() == "place" }), placeIndex + 1 < parts.count {
            return parts[placeIndex + 1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "Điểm từ bản đồ"
        }
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let value = components.queryItems?.first(where: { ["q", "query", "destination"].contains($0.name.lowercased()) })?.value,
           coordinateFromPair(value) == nil {
            return value
        }
        return "Điểm từ Google Maps/Waze"
    }
}

private struct NominatimResult: Decodable {
    let lat: String
    let lon: String
    let display_name: String
    let name: String?
}

private struct GraphHopperRouteResponse: Decodable {
    let paths: [Path]
    struct Path: Decodable {
        let distance: Double
        let time: Int64
        let points: Geometry
        let instructions: [Instruction]?
    }
    struct Geometry: Decodable { let coordinates: [[Double]] }
    struct Instruction: Decodable {
        let distance: Double
        let time: Int64
        let sign: Int
        let text: String
        let interval: [Int]?
    }
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
