import CoreImage
import CoreVideo
import Foundation
import Vision

final class TrafficSignDetector {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let allowedSpeeds = Set(stride(from: 20, through: 120, by: 10))

    // Search the places where VN traffic signs actually appear: left roadside,
    // right roadside and overhead/gantry. We deliberately overlap zones so a
    // sign close to the optical centre is not missed.
    private let speedSearchZones: [CGRect] = [
        CGRect(x: 0.00, y: 0.22, width: 0.42, height: 0.76),
        CGRect(x: 0.58, y: 0.22, width: 0.42, height: 0.76),
        CGRect(x: 0.20, y: 0.45, width: 0.60, height: 0.53)
    ]

    func detect(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [TrafficSignObservation] {
        var observations: [TrafficSignObservation] = []
        observations.append(contentsOf: try detectSpeedLimits(pixelBuffer: pixelBuffer, timestamp: timestamp))
        if let dense = try detectDenseAreaSign(pixelBuffer: pixelBuffer, timestamp: timestamp) {
            observations.append(dense)
        }
        return observations
    }

    private func detectSpeedLimits(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval
    ) throws -> [TrafficSignObservation] {
        var bestBySpeed: [Int: TrafficSignObservation] = [:]

        for zone in speedSearchZones {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            // The old value (0.018) rejected small signs at normal driving
            // distance. 0.004 keeps ~8 px text on a 1080p frame eligible.
            request.minimumTextHeight = 0.004
            request.customWords = allowedSpeeds.map(String.init)
            request.regionOfInterest = zone

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            try handler.perform([request])

            guard let results = request.results else { continue }
            for result in results {
                // Try several OCR hypotheses. Dashcam blur often makes 60 look
                // like 6O, 80 like BO, or 100 like 1OO.
                for candidate in result.topCandidates(3) {
                    guard let speed = normalizedSpeed(from: candidate.string) else { continue }

                    let fullBox = fullImageRect(result.boundingBox, in: zone)
                    let sampleRect = expandedSignRect(around: fullBox)
                    guard let appearance = appearance(in: sampleRect, pixelBuffer: pixelBuffer) else { continue }

                    // Keep the visual gate, but make it tolerant enough for
                    // distant/washed-out 70mai frames. Temporal tracking will
                    // reject one-frame false positives later.
                    guard appearance.redRatio >= 0.004,
                          appearance.brightRatio >= 0.08 else { continue }

                    let visualBonus = min(0.24, appearance.redRatio * 3.4 + appearance.brightRatio * 0.16)
                    let confidence = min(0.99, candidate.confidence + Float(visualBonus))
                    guard confidence >= 0.46 else { continue }

                    let observation = TrafficSignObservation(
                        kind: .speedLimit(speed),
                        confidence: confidence,
                        timestamp: timestamp
                    )
                    if bestBySpeed[speed]?.confidence ?? 0 < confidence {
                        bestBySpeed[speed] = observation
                    }
                    break
                }
            }
        }

        return Array(bestBySpeed.values)
    }

    private func normalizedSpeed(from text: String) -> Int? {
        let upper = text.uppercased()
        var normalized = ""
        for character in upper {
            switch character {
            case "0"..."9": normalized.append(character)
            case "O", "Q", "D": normalized.append("0")
            case "I", "L", "|": normalized.append("1")
            case "B": normalized.append("8")
            default: continue
            }
        }

        // Prefer an exact supported value, then look for one embedded in OCR
        // noise such as "(80)" or "MAX80".
        if let value = Int(normalized), allowedSpeeds.contains(value) { return value }
        for speed in allowedSpeeds.sorted(by: >) {
            if normalized.contains(String(speed)) { return speed }
        }
        return nil
    }

    private func fullImageRect(_ roiRelativeBox: CGRect, in roi: CGRect) -> CGRect {
        CGRect(
            x: roi.minX + roiRelativeBox.minX * roi.width,
            y: roi.minY + roiRelativeBox.minY * roi.height,
            width: roiRelativeBox.width * roi.width,
            height: roiRelativeBox.height * roi.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func detectDenseAreaSign(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval
    ) throws -> TrafficSignObservation? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 18
        request.minimumAspectRatio = 0.55
        request.maximumAspectRatio = 3.2
        request.minimumSize = 0.012
        request.quadratureTolerance = 28
        request.regionOfInterest = CGRect(x: 0.01, y: 0.20, width: 0.98, height: 0.79)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        guard let rectangles = request.results else { return nil }
        var best: TrafficSignObservation?

        for rect in rectangles {
            let box = fullImageRect(rect.boundingBox, in: request.regionOfInterest)
            guard box.width > 0.012,
                  box.height > 0.012,
                  box.width < 0.42,
                  box.height < 0.34 else { continue }

            let expanded = box.insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let a = appearance(in: expanded, pixelBuffer: pixelBuffer) else { continue }

            guard a.brightRatio >= 0.22,
                  a.darkRatio >= 0.025,
                  a.darkRatio <= 0.58 else { continue }

            let hasRedSlash = a.redRatio >= 0.010
            let kind: TrafficSignKind = hasRedSlash ? .denseAreaEnd : .denseAreaStart
            let structureScore = min(0.24, a.brightRatio * 0.15 + a.darkRatio * 0.46)
            let slashBonus = hasRedSlash ? min(0.10, a.redRatio * 1.9) : 0.0
            let confidence = min(0.94, rect.confidence + Float(structureScore + slashBonus))
            guard confidence >= 0.52 else { continue }

            let observation = TrafficSignObservation(kind: kind, confidence: confidence, timestamp: timestamp)
            if best?.confidence ?? 0 < confidence { best = observation }
        }

        return best
    }

    private func expandedSignRect(around textBox: CGRect) -> CGRect {
        let w = max(textBox.width * 3.2, textBox.height * 2.8)
        let h = max(textBox.height * 4.0, textBox.width * 1.8)
        return CGRect(
            x: textBox.midX - w / 2,
            y: textBox.midY - h / 2,
            width: w,
            height: h
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private struct Appearance {
        let redRatio: Double
        let brightRatio: Double
        let darkRatio: Double
    }

    private func appearance(in normalizedRect: CGRect, pixelBuffer: CVPixelBuffer) -> Appearance? {
        guard normalizedRect.width > 0.002, normalizedRect.height > 0.002 else { return nil }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let rect = CGRect(
            x: extent.minX + normalizedRect.minX * extent.width,
            y: extent.minY + normalizedRect.minY * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).intersection(extent)
        guard !rect.isEmpty else { return nil }

        let targetWidth = 64
        let targetHeight = 64
        let sx = CGFloat(targetWidth) / rect.width
        let sy = CGFloat(targetHeight) / rect.height
        let cropped = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        var pixels = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            ciContext.render(
                cropped,
                toBitmap: base,
                rowBytes: targetWidth * 4,
                bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        var red = 0
        var bright = 0
        var dark = 0
        let count = targetWidth * targetHeight

        for index in 0..<count {
            let p = index * 4
            let r = Int(pixels[p])
            let g = Int(pixels[p + 1])
            let b = Int(pixels[p + 2])
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))

            if r > 105, r > g + 22, r > b + 20 { red += 1 }
            if minRGB > 135 { bright += 1 }
            if maxRGB < 100 { dark += 1 }
        }

        return Appearance(
            redRatio: Double(red) / Double(count),
            brightRatio: Double(bright) / Double(count),
            darkRatio: Double(dark) / Double(count)
        )
    }
}
