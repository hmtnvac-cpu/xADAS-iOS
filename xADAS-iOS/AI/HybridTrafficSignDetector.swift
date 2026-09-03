import CoreImage
import CoreVideo
import Foundation
import Vision

/// Production traffic-sign pipeline:
/// 1) VTSR YOLO locates/classifies the Vietnamese sign.
/// 2) P.127 crops are OCR'd only for the numeric speed value.
/// 3) The previous heuristic detector remains a fallback while field testing.
final class HybridTrafficSignDetector {
    private let yolo: VNTrafficSignONNXDetector?
    private let fallback = TrafficSignDetector()
    private let allowedSpeeds = Set(stride(from: 20, through: 120, by: 10))

    var modeLabel: String {
        yolo == nil ? "SIGN AI • OCR FALLBACK" : "SIGN AI • VTSR YOLO"
    }

    init() {
        yolo = try? VNTrafficSignONNXDetector()
    }

    func detect(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [TrafficSignObservation] {
        var observations: [TrafficSignObservation] = []

        if let yolo {
            let detections = try yolo.detect(pixelBuffer: pixelBuffer)
            for detection in detections {
                let code = normalize(code: detection.code)

                if code.contains("P-127") || code.contains("P127") {
                    if let speed = try recognizeSpeed(in: detection.boundingBox, pixelBuffer: pixelBuffer) {
                        observations.append(TrafficSignObservation(
                            kind: .speedLimit(speed.value),
                            confidence: min(0.99, detection.confidence * 0.65 + speed.confidence * 0.35),
                            timestamp: timestamp
                        ))
                    }
                } else if code.contains("R-420") || code.contains("R420") {
                    observations.append(TrafficSignObservation(
                        kind: .denseAreaStart,
                        confidence: detection.confidence,
                        timestamp: timestamp
                    ))
                } else if code.contains("R-421") || code.contains("R421") {
                    observations.append(TrafficSignObservation(
                        kind: .denseAreaEnd,
                        confidence: detection.confidence,
                        timestamp: timestamp
                    ))
                }
            }
        }

        // Keep the old path as fallback during migration. Strong YOLO results
        // win during deduplication below.
        observations.append(contentsOf: try fallback.detect(pixelBuffer: pixelBuffer, timestamp: timestamp))

        var best: [TrafficSignKind: TrafficSignObservation] = [:]
        for observation in observations {
            if best[observation.kind]?.confidence ?? 0 < observation.confidence {
                best[observation.kind] = observation
            }
        }
        return Array(best.values)
    }

    private struct SpeedResult {
        let value: Int
        let confidence: Float
    }

    private func recognizeSpeed(in normalizedBox: CGRect, pixelBuffer: CVPixelBuffer) throws -> SpeedResult? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let expanded = normalizedBox.insetBy(
            dx: -normalizedBox.width * 0.18,
            dy: -normalizedBox.height * 0.18
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        let rect = CGRect(
            x: extent.minX + expanded.minX * extent.width,
            y: extent.minY + expanded.minY * extent.height,
            width: expanded.width * extent.width,
            height: expanded.height * extent.height
        ).intersection(extent)
        guard !rect.isEmpty else { return nil }

        let crop = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let maxSide = max(rect.width, rect.height)
        let scale = max(1.0, 384.0 / maxSide)
        let enlarged = crop.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.customWords = allowedSpeeds.map(String.init)
        request.minimumTextHeight = 0.08

        try VNImageRequestHandler(ciImage: enlarged, orientation: .up).perform([request])

        var best: SpeedResult?
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(5) {
                guard let value = normalizeSpeed(candidate.string) else { continue }
                let result = SpeedResult(value: value, confidence: candidate.confidence)
                if best?.confidence ?? 0 < result.confidence { best = result }
            }
        }
        return best
    }

    private func normalizeSpeed(_ text: String) -> Int? {
        var normalized = ""
        for character in text.uppercased() {
            switch character {
            case "0"..."9": normalized.append(character)
            case "O", "Q", "D": normalized.append("0")
            case "I", "L", "|": normalized.append("1")
            case "B": normalized.append("8")
            default: continue
            }
        }
        if let value = Int(normalized), allowedSpeeds.contains(value) { return value }
        for speed in allowedSpeeds.sorted(by: >) where normalized.contains(String(speed)) { return speed }
        return nil
    }

    private func normalize(code: String) -> String {
        code.uppercased().replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "")
    }
}
