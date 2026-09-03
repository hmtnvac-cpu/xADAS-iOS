import CoreImage
import CoreVideo
import Foundation
import Vision

final class TrafficSignDetector {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let allowedSpeeds = Set(stride(from: 20, through: 120, by: 10))

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
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.018
        request.customWords = allowedSpeeds.map(String.init)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }
        var bestBySpeed: [Int: TrafficSignObservation] = [:]

        for result in results {
            guard result.boundingBox.midY > 0.24,
                  let candidate = result.topCandidates(1).first else { continue }

            let digits = candidate.string.filter(\.isNumber)
            guard let speed = Int(digits), allowedSpeeds.contains(speed) else { continue }

            let sampleRect = expandedSignRect(around: result.boundingBox)
            guard let appearance = appearance(in: sampleRect, pixelBuffer: pixelBuffer) else { continue }
            guard appearance.redRatio >= 0.014,
                  appearance.brightRatio >= 0.16 else { continue }

            let visualBonus = min(0.18, appearance.redRatio * 2.2 + appearance.brightRatio * 0.12)
            let confidence = min(0.99, candidate.confidence + Float(visualBonus))
            let observation = TrafficSignObservation(
                kind: .speedLimit(speed),
                confidence: confidence,
                timestamp: timestamp
            )

            if bestBySpeed[speed]?.confidence ?? 0 < confidence {
                bestBySpeed[speed] = observation
            }
        }

        return Array(bestBySpeed.values)
    }

    private func detectDenseAreaSign(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval
    ) throws -> TrafficSignObservation? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 10
        request.minimumAspectRatio = 0.72
        request.maximumAspectRatio = 2.6
        request.minimumSize = 0.025
        request.quadratureTolerance = 22
        request.regionOfInterest = CGRect(x: 0.02, y: 0.24, width: 0.96, height: 0.74)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        guard let rectangles = request.results else { return nil }
        var best: TrafficSignObservation?

        for rect in rectangles {
            let box = rect.boundingBox
            guard box.width > 0.025,
                  box.height > 0.02,
                  box.width < 0.36,
                  box.height < 0.30 else { continue }

            let expanded = box.insetBy(dx: -box.width * 0.06, dy: -box.height * 0.06)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let a = appearance(in: expanded, pixelBuffer: pixelBuffer) else { continue }

            guard a.brightRatio >= 0.38,
                  a.darkRatio >= 0.055,
                  a.darkRatio <= 0.48 else { continue }

            let hasRedSlash = a.redRatio >= 0.017
            let kind: TrafficSignKind = hasRedSlash ? .denseAreaEnd : .denseAreaStart
            let structureScore = min(0.20, a.brightRatio * 0.12 + a.darkRatio * 0.42)
            let slashBonus = hasRedSlash ? min(0.09, a.redRatio * 1.6) : 0.0
            let confidence = min(0.92, rect.confidence + Float(structureScore + slashBonus))
            guard confidence >= 0.70 else { continue }

            let observation = TrafficSignObservation(kind: kind, confidence: confidence, timestamp: timestamp)
            if best?.confidence ?? 0 < confidence { best = observation }
        }

        return best
    }

    private func expandedSignRect(around textBox: CGRect) -> CGRect {
        let w = max(textBox.width * 2.5, textBox.height * 2.0)
        let h = max(textBox.height * 3.2, textBox.width * 1.4)
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

        let targetWidth = 48
        let targetHeight = 48
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

            if r > 120, r > g + 35, r > b + 30 { red += 1 }
            if minRGB > 155 { bright += 1 }
            if maxRGB < 85 { dark += 1 }
        }

        return Appearance(
            redRatio: Double(red) / Double(count),
            brightRatio: Double(bright) / Double(count),
            darkRatio: Double(dark) / Double(count)
        )
    }
}
