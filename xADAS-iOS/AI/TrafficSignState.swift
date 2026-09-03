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

    // Multi-scale scanning sees a given road zone several times per second. Three
    // consistent speed observations are therefore fast enough for driving but much
    // harder for a one-frame 60/80 confusion to flip the HUD.
    private let minimumObservationConfidence: Float = 0.28
    private let confirmationWindow: TimeInterval = 1.35
    private let speedLockScore: Float = 0.90
    private let speedChangeScore: Float = 1.05
    private let areaLockScore: Float = 0.82
    private let strongSingleHit: Float = 0.98

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

        switch observation.kind {
        case .speedLimit(let value):
            guard (10...120).contains(value), value % 10 == 0 else { return state }

            let changingExistingLimit = state.explicitSpeedLimitKPH.map { $0 != value } ?? false
            let requiredScore = changingExistingLimit ? speedChangeScore : speedLockScore
            let requiredHits = changingExistingLimit ? 3 : 3
            let confirmed = observation.confidence >= strongSingleHit
                || (candidate.hits >= requiredHits && candidate.score >= requiredScore)
            guard confirmed else { return state }

            state.explicitSpeedLimitKPH = value
            state.lastConfirmedSign = observation.kind
            state.confidence = candidate.bestConfidence
            state.updatedAt = observation.timestamp

            // Once a speed is locked, discard all competing speed evidence. A new
            // limit must build a fresh three-hit case instead of inheriting stale score.
            candidates = candidates.filter {
                if case .speedLimit = $0.key { return false }
                return true
            }

        case .denseAreaStart, .denseAreaEnd:
            let confirmed = observation.confidence >= strongSingleHit
                || (candidate.hits >= 2 && candidate.score >= areaLockScore)
            guard confirmed else { return state }

            switch observation.kind {
            case .denseAreaStart: state.denseArea = .inside
            case .denseAreaEnd: state.denseArea = .outside
            case .speedLimit: break
            }
            state.lastConfirmedSign = observation.kind
            state.confidence = candidate.bestConfidence
            state.updatedAt = observation.timestamp
            candidates.removeValue(forKey: .denseAreaStart)
            candidates.removeValue(forKey: .denseAreaEnd)
        }

        return state
    }
}
