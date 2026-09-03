import Foundation

/// Vietnamese phase-1 sign state for passenger cars (<= 7 seats).
/// Only explicit speed-limit signs and dense-area start/end signs are used.
enum DenseAreaState: String, Equatable {
    case unknown
    case inside
    case outside
}

enum TrafficSignKind: Hashable {
    case speedLimit(Int)
    case denseAreaStart   // R.420
    case denseAreaEnd     // R.421
}

struct TrafficSignObservation: Equatable {
    let kind: TrafficSignKind
    let confidence: Float
    let timestamp: TimeInterval
}

struct TrafficSignState: Equatable {
    var explicitSpeedLimitKPH: Int?
    var denseArea: DenseAreaState = .unknown
    var lastConfirmedSign: TrafficSignKind?
    var confidence: Float = 0
    var updatedAt: TimeInterval = 0

    var speedLabel: String {
        explicitSpeedLimitKPH.map { "LIMIT \($0)" } ?? "LIMIT --"
    }

    var areaLabel: String {
        switch denseArea {
        case .inside: return "DENSE"
        case .outside: return "OUTSIDE"
        case .unknown: return "AREA --"
        }
    }
}

final class TrafficSignStateTracker {
    private(set) var state = TrafficSignState()

    private struct Candidate {
        var hits: Int
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var bestConfidence: Float
    }

    private var candidates: [TrafficSignKind: Candidate] = [:]
    // Dashcam signs can be visible clearly for less than one second. Requiring
    // three high-confidence hits caused real signs to disappear before lock.
    private let minimumConfidence: Float = 0.48
    private let requiredHits = 2
    private let confirmationWindow: TimeInterval = 2.0

    func ingest(_ observation: TrafficSignObservation) -> TrafficSignState {
        guard observation.confidence >= minimumConfidence else { return state }

        candidates = candidates.filter {
            observation.timestamp - $0.value.lastSeen <= confirmationWindow
        }

        var candidate = candidates[observation.kind] ?? Candidate(
            hits: 0,
            firstSeen: observation.timestamp,
            lastSeen: observation.timestamp,
            bestConfidence: observation.confidence
        )

        if observation.timestamp - candidate.firstSeen > confirmationWindow {
            candidate = Candidate(
                hits: 0,
                firstSeen: observation.timestamp,
                lastSeen: observation.timestamp,
                bestConfidence: observation.confidence
            )
        }

        candidate.hits += 1
        candidate.lastSeen = observation.timestamp
        candidate.bestConfidence = max(candidate.bestConfidence, observation.confidence)
        candidates[observation.kind] = candidate

        guard candidate.hits >= requiredHits else { return state }

        switch observation.kind {
        case .speedLimit(let value):
            guard (20...120).contains(value), value % 10 == 0 else { return state }
            state.explicitSpeedLimitKPH = value
        case .denseAreaStart:
            state.denseArea = .inside
        case .denseAreaEnd:
            state.denseArea = .outside
        }

        state.lastConfirmedSign = observation.kind
        state.confidence = candidate.bestConfidence
        state.updatedAt = observation.timestamp
        candidates[observation.kind] = nil
        return state
    }
}
