import CoreImage
import CoreVideo
import Foundation
import Vision

final class TrafficSignDetector {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let allowedSpeeds = Set(stride(from: 20, through: 120, by: 10))

    private let speedSearchZones: [CGRect] = [
        CGRect(x: 0.00, y: 0.20, width: 0.44, height: 0.79),
        CGRect(x: 0.56, y: 0.20, width: 0.44, height: 0.79),
        CGRect(x: 0.18, y: 0.43, width: 0.64, height: 0.56)
    ]

    func detect(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) throws -> [TrafficSignObservation] {
        var observations: [TrafficSignObservation] = []

        // Primary path: find red circular roadside sign candidates first, crop
        // them, upscale them, then OCR only the sign. Full-frame OCR was the
        // main reason real 70mai speed signs were missed at normal distance.
        observations.append(contentsOf: try detectSpeedSignsByRedCandidates(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp
        ))

        // Fallback path catches washed-out signs whose red ring is weak.
        observations.append(contentsOf: try detectSpeedLimitsByZoneOCR(
            pixelBuffer: pixelBuffer,
            timestamp: timestamp
        ))

        if let dense = try detectDenseAreaSign(pixelBuffer: pixelBuffer, timestamp: timestamp) {
            observations.append(dense)
        }

        // Keep the strongest observation for each exact sign kind.
        var best: [TrafficSignKind: TrafficSignObservation] = [:]
        for observation in observations {
            if best[observation.kind]?.confidence ?? 0 < observation.confidence {
                best[observation.kind] = observation
            }
        }
        return Array(best.values)
    }

    // MARK: - Speed limit: red candidate -> crop -> OCR

    private func detectSpeedSignsByRedCandidates(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval
    ) throws -> [TrafficSignObservation] {
        let candidates = redSignCandidates(pixelBuffer: pixelBuffer)
        var results: [TrafficSignObservation] = []

        for rect in candidates.prefix(14) {
            guard let appearance = appearance(in: rect, pixelBuffer: pixelBuffer),
                  appearance.redRatio >= 0.012,
                  appearance.brightRatio >= 0.08 else { continue }

            guard let speedResult = try recognizeSpeed(in: rect, pixelBuffer: pixelBuffer) else { continue }

            let visualBonus = min(0.28, appearance.redRatio * 2.8 + appearance.brightRatio * 0.18)
            let confidence = min(0.99, speedResult.confidence + Float(visualBonus))
            guard confidence >= 0.42 else { continue }

            results.append(TrafficSignObservation(
                kind: .speedLimit(speedResult.speed),
                confidence: confidence,
                timestamp: timestamp
            ))
        }
        return results
    }

    private struct SpeedOCRResult {
        let speed: Int
        let confidence: Float
    }

    private func recognizeSpeed(in normalizedRect: CGRect, pixelBuffer: CVPixelBuffer) throws -> SpeedOCRResult? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let rect = CGRect(
            x: extent.minX + normalizedRect.minX * extent.width,
            y: extent.minY + normalizedRect.minY * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).intersection(extent)
        guard !rect.isEmpty else { return nil }

        let crop = image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let maxSide = max(rect.width, rect.height)
        let scale = max(1.0, 320.0 / maxSide)
        let enlarged = crop.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.customWords = allowedSpeeds.map(String.init)
        request.minimumTextHeight = 0.06

        let handler = VNImageRequestHandler(ciImage: enlarged, orientation: .up, options: [:])
        try handler.perform([request])

        var best: SpeedOCRResult?
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(5) {
                guard let speed = normalizedSpeed(from: candidate.string) else { continue }
                let value = SpeedOCRResult(speed: speed, confidence: candidate.confidence)
                if best?.confidence ?? 0 < value.confidence { best = value }
            }
        }
        return best
    }

    /// Downsample the frame and find connected red-ring blobs. The mask is
    /// dilated one pixel so a blurred/broken ring still becomes one candidate.
    private func redSignCandidates(pixelBuffer: CVPixelBuffer) -> [CGRect] {
        let targetWidth = 320
        let targetHeight = 180
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = CGFloat(targetWidth) / source.extent.width
        let sy = CGFloat(targetHeight) / source.extent.height
        let scaled = source.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        var rgba = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        rgba.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            ciContext.render(
                scaled,
                toBitmap: base,
                rowBytes: targetWidth * 4,
                bounds: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        let count = targetWidth * targetHeight
        var rawMask = [Bool](repeating: false, count: count)
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let i = y * targetWidth + x
                let p = i * 4
                let r = Int(rgba[p])
                let g = Int(rgba[p + 1])
                let b = Int(rgba[p + 2])
                // Broad enough for 70mai compression and sunlight, but still
                // demands red dominance over green/blue.
                rawMask[i] = r >= 92 && r >= g + 20 && r >= b + 16
            }
        }

        var mask = rawMask
        if targetWidth > 2 && targetHeight > 2 {
            for y in 1..<(targetHeight - 1) {
                for x in 1..<(targetWidth - 1) {
                    let i = y * targetWidth + x
                    guard !rawMask[i] else { continue }
                    var neighborRed = 0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            if rawMask[(y + dy) * targetWidth + (x + dx)] { neighborRed += 1 }
                        }
                    }
                    if neighborRed >= 2 { mask[i] = true }
                }
            }
        }

        var visited = [Bool](repeating: false, count: count)
        var candidates: [(rect: CGRect, score: Double)] = []
        let neighbors = [(1,0), (-1,0), (0,1), (0,-1)]

        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let start = y * targetWidth + x
                guard mask[start], !visited[start] else { continue }

                var queue: [(Int, Int)] = [(x, y)]
                visited[start] = true
                var head = 0
                var minX = x, maxX = x, minY = y, maxY = y
                var pixels = 0

                while head < queue.count {
                    let (cx, cy) = queue[head]
                    head += 1
                    pixels += 1
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)

                    for (dx, dy) in neighbors {
                        let nx = cx + dx, ny = cy + dy
                        guard nx >= 0, nx < targetWidth, ny >= 0, ny < targetHeight else { continue }
                        let ni = ny * targetWidth + nx
                        if mask[ni], !visited[ni] {
                            visited[ni] = true
                            queue.append((nx, ny))
                        }
                    }
                }

                let w = maxX - minX + 1
                let h = maxY - minY + 1
                guard pixels >= 5,
                      w >= 3, h >= 3,
                      w <= 52, h <= 52 else { continue }

                let aspect = Double(w) / Double(h)
                guard aspect >= 0.48, aspect <= 2.05 else { continue }
                let fill = Double(pixels) / Double(w * h)
                guard fill >= 0.045, fill <= 0.82 else { continue }

                let cx = Double(minX + maxX + 1) / 2.0
                let cy = Double(minY + maxY + 1) / 2.0
                let side = Double(max(w, h)) * 2.45
                var rect = CGRect(
                    x: (cx - side / 2) / Double(targetWidth),
                    y: (cy - side / 2) / Double(targetHeight),
                    width: side / Double(targetWidth),
                    height: side / Double(targetHeight)
                ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

                // Ignore the bottom dashboard/bonnet region and microscopic or
                // huge red objects that cannot be a traffic sign.
                guard rect.midY >= 0.22,
                      rect.width >= 0.018,
                      rect.width <= 0.22 else { continue }

                // Keep crop square in normalized image coordinates as much as possible.
                let normalizedSide = max(rect.width, rect.height)
                rect = CGRect(
                    x: rect.midX - normalizedSide / 2,
                    y: rect.midY - normalizedSide / 2,
                    width: normalizedSide,
                    height: normalizedSide
                ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

                let squareness = 1.0 - min(1.0, abs(1.0 - aspect))
                let score = Double(pixels) * (0.5 + squareness) * (0.5 + min(fill, 0.5))
                candidates.append((rect, score))
            }
        }

        return candidates.sorted { $0.score > $1.score }.map(\.rect)
    }

    // MARK: - Fallback speed OCR

    private func detectSpeedLimitsByZoneOCR(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval
    ) throws -> [TrafficSignObservation] {
        var bestBySpeed: [Int: TrafficSignObservation] = [:]

        for zone in speedSearchZones {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.0035
            request.customWords = allowedSpeeds.map(String.init)
            request.regionOfInterest = zone

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            try handler.perform([request])

            guard let results = request.results else { continue }
            for result in results {
                for candidate in result.topCandidates(3) {
                    guard let speed = normalizedSpeed(from: candidate.string) else { continue }
                    let fullBox = fullImageRect(result.boundingBox, in: zone)
                    let sampleRect = expandedSignRect(around: fullBox)
                    guard let a = appearance(in: sampleRect, pixelBuffer: pixelBuffer),
                          a.redRatio >= 0.003,
                          a.brightRatio >= 0.065 else { continue }

                    let confidence = min(0.92, candidate.confidence + Float(min(0.20, a.redRatio * 3.0 + a.brightRatio * 0.14)))
                    guard confidence >= 0.38 else { continue }
                    let observation = TrafficSignObservation(kind: .speedLimit(speed), confidence: confidence, timestamp: timestamp)
                    if bestBySpeed[speed]?.confidence ?? 0 < confidence { bestBySpeed[speed] = observation }
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

        if let value = Int(normalized), allowedSpeeds.contains(value) { return value }
        for speed in allowedSpeeds.sorted(by: >) where normalized.contains(String(speed)) { return speed }
        return nil
    }

    // MARK: - Dense population area R.420 / R.421

    private func detectDenseAreaSign(
        pixelBuffer: CVPixelBuffer,
        timestamp: TimeInterval
    ) throws -> TrafficSignObservation? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 24
        request.minimumAspectRatio = 0.50
        request.maximumAspectRatio = 3.4
        request.minimumSize = 0.009
        request.quadratureTolerance = 30
        request.regionOfInterest = CGRect(x: 0.01, y: 0.20, width: 0.98, height: 0.79)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try handler.perform([request])

        guard let rectangles = request.results else { return nil }
        var best: TrafficSignObservation?

        for rectangle in rectangles {
            let box = fullImageRect(rectangle.boundingBox, in: request.regionOfInterest)
            guard box.width > 0.010,
                  box.height > 0.010,
                  box.width < 0.42,
                  box.height < 0.34 else { continue }

            let expanded = box.insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let a = appearance(in: expanded, pixelBuffer: pixelBuffer) else { continue }

            // White rectangular board + dark settlement silhouette. R.421 has
            // the red diagonal slash, so red density separates end/start.
            guard a.brightRatio >= 0.18,
                  a.darkRatio >= 0.022,
                  a.darkRatio <= 0.62 else { continue }

            let hasRedSlash = a.redRatio >= 0.008
            let kind: TrafficSignKind = hasRedSlash ? .denseAreaEnd : .denseAreaStart
            let structure = min(0.24, a.brightRatio * 0.16 + a.darkRatio * 0.44)
            let slashBonus = hasRedSlash ? min(0.11, a.redRatio * 2.0) : 0.0
            let confidence = min(0.93, rectangle.confidence + Float(structure + slashBonus))
            guard confidence >= 0.48 else { continue }

            let observation = TrafficSignObservation(kind: kind, confidence: confidence, timestamp: timestamp)
            if best?.confidence ?? 0 < confidence { best = observation }
        }
        return best
    }

    // MARK: - Shared helpers

    private func fullImageRect(_ roiRelativeBox: CGRect, in roi: CGRect) -> CGRect {
        CGRect(
            x: roi.minX + roiRelativeBox.minX * roi.width,
            y: roi.minY + roiRelativeBox.minY * roi.height,
            width: roiRelativeBox.width * roi.width,
            height: roiRelativeBox.height * roi.height
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func expandedSignRect(around textBox: CGRect) -> CGRect {
        let w = max(textBox.width * 3.4, textBox.height * 3.0)
        let h = max(textBox.height * 4.2, textBox.width * 1.9)
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

        var red = 0, bright = 0, dark = 0
        let count = targetWidth * targetHeight
        for index in 0..<count {
            let p = index * 4
            let r = Int(pixels[p])
            let g = Int(pixels[p + 1])
            let b = Int(pixels[p + 2])
            let maxRGB = max(r, max(g, b))
            let minRGB = min(r, min(g, b))
            if r > 92, r > g + 18, r > b + 16 { red += 1 }
            if minRGB > 128 { bright += 1 }
            if maxRGB < 105 { dark += 1 }
        }

        return Appearance(
            redRatio: Double(red) / Double(count),
            brightRatio: Double(bright) / Double(count),
            darkRatio: Double(dark) / Double(count)
        )
    }
}
