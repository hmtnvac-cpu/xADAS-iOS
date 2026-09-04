import Combine
import CoreLocation
import Foundation

/// Matches a short GPS trace to OpenStreetMap roads through Valhalla and reads
/// the posted `edge.speed_limit` value. No API token or billing account required.
final class MapSpeedLimitProvider: ObservableObject {
    @Published private(set) var speedLimitKPH: Int?
    @Published private(set) var status = "OSM LIMIT • READY"
    @Published private(set) var lastUpdatedAt: Date?

    private var trace: [CLLocation] = []
    private var lastRequestAt: TimeInterval = 0
    private var task: URLSessionDataTask?
    private let minimumRequestInterval: TimeInterval = 5.0
    private let maximumTracePoints = 8
    private let clientID = "ivy-adas-ios"

    func ingest(location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 35 else {
            status = "OSM LIMIT • GPS WEAK"
            return
        }
        if let last = trace.last, location.distance(from: last) < 2.0 { return }
        trace.append(location)
        if trace.count > maximumTracePoints { trace.removeFirst(trace.count - maximumTracePoints) }
        guard trace.count >= 3 else {
            status = "OSM LIMIT • GPS TRACE"
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRequestAt >= minimumRequestInterval else { return }
        lastRequestAt = now
        requestMatch()
    }

    private func requestMatch() {
        let points = trace.suffix(maximumTracePoints).map {
            ValhallaTraceRequest.Point(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude, time: Int($0.timestamp.timeIntervalSince1970))
        }
        let payload = ValhallaTraceRequest(
            shape: points,
            costing: "auto",
            shape_match: "map_snap",
            filters: .init(action: "include", attributes: ["edge.speed_limit", "edge.speed", "edge.osm_id"])
        )
        guard let url = URL(string: "https://valhalla1.openstreetmap.de/trace_attributes"),
              let body = try? JSONEncoder().encode(payload) else {
            status = "OSM LIMIT • URL ERROR"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientID, forHTTPHeaderField: "X-Client-Id")
        request.setValue("IvyADAS/1.0 (iOS; personal navigation project)", forHTTPHeaderField: "User-Agent")

        task?.cancel()
        status = "OSM LIMIT • MATCHING"
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data else {
                DispatchQueue.main.async { self.status = "OSM LIMIT • NET ERROR" }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(ValhallaTraceResponse.self, from: data)
                let limit = decoded.edges.reversed().compactMap(\.speed_limit).first.flatMap { $0 > 0 && $0 < 200 ? $0 : nil }
                DispatchQueue.main.async {
                    self.speedLimitKPH = limit
                    self.lastUpdatedAt = Date()
                    self.status = limit.map { "OSM LIMIT • \($0)" } ?? "OSM LIMIT • UNKNOWN"
                }
            } catch {
                DispatchQueue.main.async { self.status = "OSM LIMIT • PARSE ERROR" }
            }
        }
        task?.resume()
    }
}

private struct ValhallaTraceRequest: Encodable {
    struct Point: Encodable { let lat: Double; let lon: Double; let time: Int }
    struct Filters: Encodable { let action: String; let attributes: [String] }
    let shape: [Point]
    let costing: String
    let shape_match: String
    let filters: Filters
}

private struct ValhallaTraceResponse: Decodable {
    struct Edge: Decodable {
        let speed_limit: Int?
        let speed: Int?
        let osm_id: Int64?
    }
    let edges: [Edge]
}
