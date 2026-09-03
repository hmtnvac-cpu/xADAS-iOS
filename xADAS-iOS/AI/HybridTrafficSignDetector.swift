import CoreVideo
import Foundation

/// Reliable traffic-sign pipeline for xADAS.
/// VN82 YOLO is authoritative whenever bundled. We intentionally use the proven
/// full-frame path only; the experimental multi-scale crop path caused field misses.
final class HybridTrafficSignDetector {
    private let directDetector: VNTrafficSign82Detector?
    private let fallback = TrafficSignDetector()

    var modeLabel: String {
        directDetector == nil ? "SIGN AI • OCR FALLBACK" : "SIGN AI • VN82 YOLO"
    }

    init() {
        directDetector = try? VNTrafficSign82Detector()
    }

    func detect(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [TrafficSignObservation] {
        guard let directDetector else {
            return try fallback.detect(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }

        // Lower raw threshold improves early/distant candidate pickup. Temporal
        // tracking below is responsible for rejecting unstable one-frame noise.
        let detections = try directDetector.detect(
            pixelBuffer: pixelBuffer,
            confidenceThreshold: 0.18
        )

        let mapped = detections.compactMap { detection -> TrafficSignObservation? in
            guard let kind = trafficSignKind(forClassID: detection.classID) else { return nil }
            return TrafficSignObservation(
                kind: kind,
                confidence: detection.confidence,
                timestamp: timestamp
            )
        }

        var result: [TrafficSignObservation] = []

        // Only one speed candidate per frame is allowed into temporal tracking.
        if let bestSpeed = mapped.filter({
            if case .speedLimit = $0.kind { return true }
            return false
        }).max(by: { $0.confidence < $1.confidence }) {
            result.append(bestSpeed)
        }

        if let bestArea = mapped.filter({
            switch $0.kind {
            case .denseAreaStart, .denseAreaEnd: return true
            case .speedLimit: return false
            }
        }).max(by: { $0.confidence < $1.confidence }) {
            result.append(bestArea)
        }

        return result
    }

    private func trafficSignKind(forClassID id: Int) -> TrafficSignKind? {
        switch id {
        case 57: return .speedLimit(10)
        case 61: return .speedLimit(20)
        case 62: return .speedLimit(30)
        case 2: return .speedLimit(40)
        case 39: return .speedLimit(50)
        case 12: return .speedLimit(60)
        case 40: return .speedLimit(70)
        case 41: return .speedLimit(80)
        case 63: return .speedLimit(90)
        case 58: return .speedLimit(100)
        case 59: return .speedLimit(110)
        case 60: return .speedLimit(120)
        case 79: return .denseAreaStart
        case 80: return .denseAreaEnd
        default: return nil
        }
    }
}
