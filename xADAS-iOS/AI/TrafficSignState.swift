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
    case denseAreaStart
    case denseAreaEnd
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
        var score: Float
        var hits: Int
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var bestConfidence: Float
    }

    private var candidates: [TrafficSignKind: Candidate] = [:]

    // Tuned for live driving: require repeat evidence, but keep the window short
    // enough that a roadside sign can lock before the car passes it.
    private let minimumObservationConfidence: Float = 0.32
    private let confirmationWindow: TimeInterval = 1.25
    private let speedLockScore: Float = 0.86
    private let areaLockScore: Float = 0.92
    private let strongSingleHit: Float = 0.95

    func ingest(_ observation: TrafficSignObservation) -> TrafficSignState {
        guard observation.confidence >= minimumObservationConfidence else { return state }

        candidates = candidates.filter {
            observation.timestamp - $0.value.lastSeen <= confirmationWindow
        }

        var candidate = candidates[observation.kind] ?? Candidate(
            score: 0,
            hits: 0,
            firstSeen: observation.timestamp,
            lastSeen: observation.timestamp,
            bestConfidence: observation.confidence
        )

        if observation.timestamp - candidate.firstSeen > confirmationWindow {
            candidate = Candidate(
                score: 0,
                hits: 0,
                firstSeen: observation.timestamp,
                lastSeen: observation.timestamp,
                bestConfidence: observation.confidence
            )
        }

        candidate.hits += 1
        candidate.lastSeen = observation.timestamp
        candidate.bestConfidence = max(candidate.bestConfidence, observation.confidence)
        candidate.score += observation.confidence
        candidates[observation.kind] = candidate

        let threshold: Float
        switch observation.kind {
        case .speedLimit: threshold = speedLockScore
        case .denseAreaStart, .denseAreaEnd: threshold = areaLockScore
        }

        // One exceptionally strong result may lock immediately. Normal detections
        // need two consistent observations; this prevents 60/80 flicker.
        let confirmed = observation.confidence >= strongSingleHit
            || (candidate.hits >= 2 && candidate.score >= threshold)
        guard confirmed else { return state }

        switch observation.kind {
        case .speedLimit(let value):
            guard (10...120).contains(value), value % 10 == 0 else { return state }
            state.explicitSpeedLimitKPH = value
        case .denseAreaStart:
            state.denseArea = .inside
        case .denseAreaEnd:
            state.denseArea = .outside
        }

        state.lastConfirmedSign = observation.kind
        state.confidence = candidate.bestConfidence
        state.updatedAt = observation.timestamp

        switch observation.kind {
        case .speedLimit:
            candidates = candidates.filter {
                if case .speedLimit = $0.key { return false }
                return true
            }
        case .denseAreaStart, .denseAreaEnd:
            candidates.removeValue(forKey: .denseAreaStart)
            candidates.removeValue(forKey: .denseAreaEnd)
        }
        return state
    }
}
