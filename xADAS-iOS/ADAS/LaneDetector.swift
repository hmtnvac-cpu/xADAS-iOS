import CoreGraphics
import CoreVideo
import Foundation

final class LaneDetector {
    private struct Sample {
        let x: Double
        let y: Double
        let weight: Double
    }

    private struct LineFit {
        let slope: Double
        let intercept: Double
        let meanResidual: Double

        func x(at y: Double) -> Double {
            slope * y + intercept
        }
    }

    func detect(pixelBuffer: CVPixelBuffer) -> LaneDetection? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard width >= 640, height >= 360 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let baseAddress = isPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let bytesPerRow = isPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)

        let startY = Int(Double(height) * 0.54)
        let endY = Int(Double(height) * 0.92)
        let rowStep = max(8, height / 80)
        let xStep = max(2, width / 960)

        var leftSamples: [Sample] = []
        var rightSamples: [Sample] = []

        for y in stride(from: startY, through: endY, by: rowStep) {
            let yNorm = Double(y) / Double(height)
            let row = baseAddress
                .advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt8.self)

            if let sample = strongestLaneEdge(
                row: row,
                width: width,
                yNorm: yNorm,
                xMinNorm: 0.08,
                xMaxNorm: 0.48,
                xStep: xStep,
                preferLeft: true
            ) {
                leftSamples.append(sample)
            }

            if let sample = strongestLaneEdge(
                row: row,
                width: width,
                yNorm: yNorm,
                xMinNorm: 0.52,
                xMaxNorm: 0.92,
                xStep: xStep,
                preferLeft: false
            ) {
                rightSamples.append(sample)
            }
        }

        guard let leftFit = robustFit(samples: leftSamples),
              let rightFit = robustFit(samples: rightSamples) else {
            return nil
        }

        let evaluationY = 0.86
        let leftX = leftFit.x(at: evaluationY)
        let rightX = rightFit.x(at: evaluationY)
        let laneWidth = rightX - leftX

        guard leftX > -0.15,
              rightX < 1.15,
              laneWidth >= 0.20,
              laneWidth <= 0.78 else {
            return nil
        }

        let laneCenter = (leftX + rightX) / 2.0
        let halfWidth = laneWidth / 2.0
        let vehicleX = 0.5
        let normalizedOffset = (vehicleX - laneCenter) / halfWidth

        let leftCountScore = min(Double(leftSamples.count) / 24.0, 1.0)
        let rightCountScore = min(Double(rightSamples.count) / 24.0, 1.0)
        let residualScore = max(
            0,
            1.0 - ((leftFit.meanResidual + rightFit.meanResidual) / 0.10)
        )
        let confidence = min(leftCountScore, rightCountScore) * residualScore

        guard confidence >= 0.28 else { return nil }

        let yValues: [Double] = [0.56, 0.61, 0.66, 0.71, 0.76, 0.81, 0.86, 0.91]
        let leftPoints = yValues.map {
            CGPoint(x: clamp(leftFit.x(at: $0)), y: $0)
        }
        let rightPoints = yValues.map {
            CGPoint(x: clamp(rightFit.x(at: $0)), y: $0)
        }

        return LaneDetection(
            leftPoints: leftPoints,
            rightPoints: rightPoints,
            confidence: confidence,
            normalizedCenterOffset: normalizedOffset
        )
    }

    private func strongestLaneEdge(
        row: UnsafePointer<UInt8>,
        width: Int,
        yNorm: Double,
        xMinNorm: Double,
        xMaxNorm: Double,
        xStep: Int,
        preferLeft: Bool
    ) -> Sample? {
        let startX = max(4, Int(Double(width) * xMinNorm))
        let endX = min(width - 5, Int(Double(width) * xMaxNorm))

        var bestX = 0
        var bestScore = 0.0

        for x in stride(from: startX, through: endX, by: xStep) {
            let left = Int(row[x - 3])
            let right = Int(row[x + 3])
            let center = Int(row[x])
            let gradient = abs(right - left)
            let brightness = center

            guard gradient >= 18, brightness >= 65 else { continue }

            let xNorm = Double(x) / Double(width)
            let expectedX = expectedLaneX(yNorm: yNorm, left: preferLeft)
            let geometryPenalty = abs(xNorm - expectedX) * 42.0
            let brightnessBonus = Double(max(brightness - 80, 0)) * 0.08
            let score = Double(gradient) + brightnessBonus - geometryPenalty

            if score > bestScore {
                bestScore = score
                bestX = x
            }
        }

        guard bestScore >= 22 else { return nil }

        return Sample(
            x: Double(bestX) / Double(width),
            y: yNorm,
            weight: min(bestScore / 90.0, 2.0)
        )
    }

    private func expectedLaneX(yNorm: Double, left: Bool) -> Double {
        let t = min(max((yNorm - 0.54) / (0.92 - 0.54), 0), 1)
        if left {
            return 0.46 - 0.28 * t
        } else {
            return 0.54 + 0.28 * t
        }
    }

    private func robustFit(samples: [Sample]) -> LineFit? {
        guard samples.count >= 8 else { return nil }
        guard let first = weightedFit(samples: samples) else { return nil }

        let filtered = samples.filter {
            abs($0.x - first.x(at: $0.y)) <= 0.075
        }

        guard filtered.count >= 7 else { return nil }
        return weightedFit(samples: filtered)
    }

    private func weightedFit(samples: [Sample]) -> LineFit? {
        var sumW = 0.0
        var sumY = 0.0
        var sumX = 0.0
        var sumYY = 0.0
        var sumYX = 0.0

        for sample in samples {
            let w = max(sample.weight, 0.1)
            sumW += w
            sumY += w * sample.y
            sumX += w * sample.x
            sumYY += w * sample.y * sample.y
            sumYX += w * sample.y * sample.x
        }

        let denominator = sumW * sumYY - sumY * sumY
        guard abs(denominator) > 0.000_001 else { return nil }

        let slope = (sumW * sumYX - sumY * sumX) / denominator
        let intercept = (sumX - slope * sumY) / sumW

        let residual = samples.reduce(0.0) { partial, sample in
            partial + abs(sample.x - (slope * sample.y + intercept))
        } / Double(samples.count)

        guard slope.isFinite,
              intercept.isFinite,
              residual.isFinite,
              abs(slope) <= 1.8 else {
            return nil
        }

        return LineFit(
            slope: slope,
            intercept: intercept,
            meanResidual: residual
        )
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
