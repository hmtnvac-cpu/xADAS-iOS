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
        var score: Float
        var hits: Int
        var firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var bestConfidence: Float
    }

    private var candidates: [TrafficSignKind: Candidate] = [:]

    // 70mai snapshots are intermittent; do not require adjacent detections.
    // Accumulate evidence for the same semantic sign over a short window.
    private let minimumObservationConfidence: Float = 0.28
    private let confirmationWindow: TimeInterval = 3.0
    private let speedLockScore: Float = 1.05
    private let areaLockScore: Float = 1.15
    private let strongSingleHit: Float = 0.88

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

        // A very strong detector result can lock immediately. Otherwise require
        // at least two observations whose confidence accumulates past threshold.
        let confirmed = observation.confidence >= strongSingleHit
            || (candidate.hits >= 2 && candidate.score >= threshold)
        guard confirmed else { return state }

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

        // A confirmed speed supersedes competing speed candidates; likewise for
        // area signs. This prevents stale candidates from immediately flipping HUD.
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
