import Foundation

/// Phase-1 Vietnamese traffic-sign state for passenger cars (<= 7 seats).
/// Recognition is intentionally limited to explicit speed-limit signs and
/// R.420/R.421 dense-population-area signs. Road-type inference comes later.
enum DenseAreaState: String, Equatable {
    case unknown
    case inside
    case outside
}

enum TrafficSignKind: Equatable {
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
        explicitSpeedLimitKPH.map { "SPEED LIMIT • \($0)" } ?? "SPEED LIMIT • --"
    }

    var areaLabel: String {
        switch denseArea {
        case .inside: return "AREA • DENSE"
        case .outside: return "AREA • OUTSIDE"
        case .unknown: return "AREA • UNKNOWN"
        }
    }
}

/// Temporal confirmation prevents one-frame false positives from changing the
/// legal-state display. A sign must be seen repeatedly in a short time window.
final class TrafficSignStateTracker {
    private(set) var state = TrafficSignState()
    private var candidate: TrafficSignKind?
    private var candidateHits = 0
    private var candidateFirstSeen: TimeInterval = 0

    private let minimumConfidence: Float = 0.72
    private let requiredHits = 3
    private let confirmationWindow: TimeInterval = 1.2

    func ingest(_ observation: TrafficSignObservation) -> TrafficSignState {
        guard observation.confidence >= minimumConfidence else { return state }

        if candidate == observation.kind,
           observation.timestamp - candidateFirstSeen <= confirmationWindow {
            candidateHits += 1
        } else {
            candidate = observation.kind
            candidateHits = 1
            candidateFirstSeen = observation.timestamp
        }

        guard candidateHits >= requiredHits else { return state }

        switch observation.kind {
        case .speedLimit(let value):
            // Phase 1 only accepts plausible explicit P.127 values. This is
            // recognition state, not road-type-derived legal inference.
            guard (20...120).contains(value), value % 10 == 0 else { return state }
            state.explicitSpeedLimitKPH = value
        case .denseAreaStart:
            state.denseArea = .inside
        case .denseAreaEnd:
            state.denseArea = .outside
        }

        state.lastConfirmedSign = observation.kind
        state.confidence = observation.confidence
        state.updatedAt = observation.timestamp
        candidateHits = 0
        candidate = nil
        return state
    }
}
