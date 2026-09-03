import CoreVideo
import Foundation

/// Production traffic-sign pipeline for xADAS.
/// Primary path uses an 82-class Vietnam YOLO11 model where each speed limit is
/// already its own class, so 60/80/90 etc. do not depend on OCR.
/// Existing VTSR/OCR remains only as a fallback while the direct model is field-tested.
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
        var observations: [TrafficSignObservation] = []

        if let directDetector {
            let detections = try directDetector.detect(pixelBuffer: pixelBuffer)
            for detection in detections {
                if let kind = trafficSignKind(forClassID: detection.classID) {
                    observations.append(TrafficSignObservation(
                        kind: kind,
                        confidence: detection.confidence,
                        timestamp: timestamp
                    ))
                }
            }
        }

        // Fallback remains available so a temporary direct-model miss does not
        // remove functionality that already produced occasional raw LIMIT hits.
        observations.append(contentsOf: try fallback.detect(pixelBuffer: pixelBuffer, timestamp: timestamp))

        var best: [TrafficSignKind: TrafficSignObservation] = [:]
        for observation in observations {
            if best[observation.kind]?.confidence ?? 0 < observation.confidence {
                best[observation.kind] = observation
            }
        }
        return Array(best.values)
    }

    /// Class IDs come directly from the published 82-class dataset/model.
    /// We intentionally map only the signs xADAS currently acts on.
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
        case 79: return .denseAreaStart       // Residential area
        case 80: return .denseAreaEnd         // Sparsely populated area
        default: return nil
        }
    }
}
