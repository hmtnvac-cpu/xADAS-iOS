import CoreGraphics
import CoreVideo
import Foundation

/// Production traffic-sign pipeline for xADAS.
/// VN82 YOLO is authoritative when available. To improve long-range detection,
/// each invocation rotates between full-frame and overlapping left/right road crops.
/// This increases effective pixels on small roadside signs without multiplying
/// inference cost on every frame.
final class HybridTrafficSignDetector {
    private let directDetector: VNTrafficSign82Detector?
    private let fallback = TrafficSignDetector()
    private var scanPhase = 0

    var modeLabel: String {
        directDetector == nil ? "SIGN AI • OCR FALLBACK" : "SIGN AI • VN82 MULTISCALE"
    }

    init() {
        directDetector = try? VNTrafficSign82Detector()
    }

    func detect(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [TrafficSignObservation] {
        guard let directDetector else {
            return try fallback.detect(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }

        let crop: CGRect?
        let threshold: Float
        switch scanPhase {
        case 1:
            // Left/center road zone. A 62%-wide crop makes a distant sign ~1.6x larger.
            crop = CGRect(x: 0.0, y: 0.0, width: 0.62, height: 0.84)
            threshold = 0.24
        case 2:
            // Right/center road zone; overlaps the left crop so center signs are not missed.
            crop = CGRect(x: 0.38, y: 0.0, width: 0.62, height: 0.84)
            threshold = 0.24
        default:
            crop = nil
            threshold = 0.28
        }
        scanPhase = (scanPhase + 1) % 3

        let detections = try directDetector.detect(
            pixelBuffer: pixelBuffer,
            normalizedCropTopLeft: crop,
            confidenceThreshold: threshold
        )
        let mapped = detections.compactMap { detection -> TrafficSignObservation? in
            guard let kind = trafficSignKind(forClassID: detection.classID) else { return nil }
            return TrafficSignObservation(
                kind: kind,
                confidence: detection.confidence,
                timestamp: timestamp
            )
        }

        // Only one speed result from one inference pass is allowed into temporal tracking.
        // OCR is intentionally NOT run when VN82 exists, because OCR competition was a
        // remaining source of 60 <-> 80 flips when the direct model briefly missed.
        var result: [TrafficSignObservation] = []
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
