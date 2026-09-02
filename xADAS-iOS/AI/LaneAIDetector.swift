import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import OnnxRuntimeBindings

enum LaneAIDetectorError: LocalizedError {
    case modelMissing
    case invalidFrame
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "UFLD V2 lane model is not bundled with the app."
        case .invalidFrame:
            return "Could not prepare the 70mai frame for lane inference."
        case .invalidOutput(let name):
            return "UFLD V2 returned an invalid \(name) tensor."
        }
    }
}

/// Real lane recognition using Ultra-Fast-Lane-Detection V2 (TuSimple, ResNet-18).
/// The bundled ONNX model is weight-quantized and runs fully on device.
final class LaneAIDetector {
    private static let inputWidth = 800
    private static let resizedHeight = 400
    private static let inputHeight = 320
    private static let gridCount = 100
    private static let rowCount = 56
    private static let laneCount = 4

    private let environment: ORTEnv
    private let session: ORTSession
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init() throws {
        guard let modelURL = Bundle.main.url(
            forResource: "UFLDv2TuSimpleRes18Int8",
            withExtension: "onnx"
        ) else {
            throw LaneAIDetectorError.modelMissing
        }

        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)

        // Unsupported quantized operators automatically stay on CPU. Supported
        // subgraphs can still use Apple's Core ML execution provider.
        if ORTIsCoreMLExecutionProviderAvailable() {
            let coreMLOptions = ORTCoreMLExecutionProviderOptions()
            coreMLOptions.enableOnSubgraphs = true
            try? options.appendCoreMLExecutionProvider(with: coreMLOptions)
        }

        session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
    }

    func detect(pixelBuffer: CVPixelBuffer) throws -> LaneDetection? {
        let input = try makeInput(pixelBuffer: pixelBuffer)
        let inputData = input.withUnsafeBufferPointer { Data(buffer: $0) }
        let inputValue = try ORTValue(
            tensorData: NSMutableData(data: inputData),
            elementType: .float,
            shape: [
                NSNumber(value: 1),
                NSNumber(value: 3),
                NSNumber(value: Self.inputHeight),
                NSNumber(value: Self.inputWidth)
            ]
        )

        let outputs = try session.run(
            withInputs: ["input": inputValue],
            outputNames: ["loc_row", "exist_row"],
            runOptions: nil
        )

        guard let locValue = outputs["loc_row"],
              let existValue = outputs["exist_row"] else {
            throw LaneAIDetectorError.invalidOutput("lane")
        }

        let locRow: [Float32] = try floatArray(from: locValue, name: "loc_row")
        let existRow: [Float32] = try floatArray(from: existValue, name: "exist_row")

        guard locRow.count == Self.gridCount * Self.rowCount * Self.laneCount,
              existRow.count == 2 * Self.rowCount * Self.laneCount else {
            throw LaneAIDetectorError.invalidOutput("shape")
        }

        guard let left = decodeLane(index: 1, locRow: locRow, existRow: existRow),
              let right = decodeLane(index: 2, locRow: locRow, existRow: existRow),
              left.points.count >= 14,
              right.points.count >= 14 else {
            return nil
        }

        let evaluationY = 0.86
        guard let leftX = fittedX(points: left.points, at: evaluationY),
              let rightX = fittedX(points: right.points, at: evaluationY) else {
            return nil
        }

        let laneWidth = rightX - leftX
        guard laneWidth >= 0.18, laneWidth <= 0.78 else { return nil }

        let confidence = min(left.confidence, right.confidence)
        guard confidence >= 0.38 else { return nil }

        let laneCenter = (leftX + rightX) / 2
        let savedCenter = UserDefaults.standard.double(
            forKey: DistanceEstimator.cameraCenterXKey
        )
        let cameraCenter = savedCenter > 0.1 ? savedCenter : 0.5
        let normalizedOffset = (cameraCenter - laneCenter) / (laneWidth / 2)

        return LaneDetection(
            leftPoints: left.points,
            rightPoints: right.points,
            confidence: confidence,
            normalizedCenterOffset: normalizedOffset
        )
    }

    private func makeInput(pixelBuffer: CVPixelBuffer) throws -> [Float32] {
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else {
            throw LaneAIDetectorError.invalidFrame
        }

        var prepared: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.inputWidth,
            Self.inputHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &prepared
        )
        guard result == kCVReturnSuccess, let prepared else {
            throw LaneAIDetectorError.invalidFrame
        }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let resized = source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(Self.inputWidth) / sourceWidth,
            y: CGFloat(Self.resizedHeight) / sourceHeight
        ))
        // UFLD TuSimple preprocessing removes the top 20% after resizing.
        let roadCrop = resized.cropped(to: CGRect(
            x: 0,
            y: 0,
            width: Self.inputWidth,
            height: Self.inputHeight
        ))
        ciContext.render(
            roadCrop,
            to: prepared,
            bounds: CGRect(x: 0, y: 0, width: Self.inputWidth, height: Self.inputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        CVPixelBufferLockBaseAddress(prepared, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(prepared, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(prepared) else {
            throw LaneAIDetectorError.invalidFrame
        }

        let pixelCount = Self.inputWidth * Self.inputHeight
        let rowBytes = CVPixelBufferGetBytesPerRow(prepared)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var tensor = [Float32](repeating: 0, count: pixelCount * 3)
        let mean: [Float32] = [0.485, 0.456, 0.406]
        let standardDeviation: [Float32] = [0.229, 0.224, 0.225]

        for y in 0..<Self.inputHeight {
            let row = bytes.advanced(by: y * rowBytes)
            for x in 0..<Self.inputWidth {
                let pixel = row.advanced(by: x * 4)
                let index = y * Self.inputWidth + x
                let red = Float32(pixel[2]) / 255
                let green = Float32(pixel[1]) / 255
                let blue = Float32(pixel[0]) / 255
                tensor[index] = (red - mean[0]) / standardDeviation[0]
                tensor[pixelCount + index] = (green - mean[1]) / standardDeviation[1]
                tensor[2 * pixelCount + index] = (blue - mean[2]) / standardDeviation[2]
            }
        }
        return tensor
    }

    private func decodeLane(
        index lane: Int,
        locRow: [Float32],
        existRow: [Float32]
    ) -> (points: [CGPoint], confidence: Double)? {
        var points: [CGPoint] = []
        var existenceTotal = 0.0

        for row in 0..<Self.rowCount {
            let absent = existRow[existIndex(classIndex: 0, row: row, lane: lane)]
            let present = existRow[existIndex(classIndex: 1, row: row, lane: lane)]
            // Match UFLD V2's reference decoder: class 1 wins when the
            // model says that this row anchor contains a lane point.  A
            // second arbitrary probability threshold was discarding valid
            // points on real 70mai frames.
            guard present > absent else { continue }
            let existence = softmaxSecond(absent, present)

            var maxGrid = 0
            var maxLogit = -Float32.greatestFiniteMagnitude
            for grid in 0..<Self.gridCount {
                let value = locRow[locIndex(grid: grid, row: row, lane: lane)]
                if value > maxLogit {
                    maxLogit = value
                    maxGrid = grid
                }
            }

            let lower = max(0, maxGrid - 1)
            let upper = min(Self.gridCount - 1, maxGrid + 1)
            var denominator = 0.0
            var numerator = 0.0
            for grid in lower...upper {
                let weight = exp(Double(locRow[locIndex(grid: grid, row: row, lane: lane)] - maxLogit))
                denominator += weight
                numerator += weight * Double(grid)
            }
            guard denominator > 0 else { continue }

            let gridPosition = numerator / denominator + 0.5
            let x = gridPosition / Double(Self.gridCount - 1)
            let y = Double(160 + row * 10) / 720.0
            guard x.isFinite, y >= 0.42 else { continue }
            points.append(CGPoint(x: min(max(x, 0), 1), y: y))
            existenceTotal += existence
        }

        guard !points.isEmpty else { return nil }
        let validRatio = Double(points.count) / Double(Self.rowCount)
        let meanExistence = existenceTotal / Double(points.count)
        return (points, min(1, validRatio * 1.35) * meanExistence)
    }

    private func locIndex(grid: Int, row: Int, lane: Int) -> Int {
        (grid * Self.rowCount + row) * Self.laneCount + lane
    }

    private func existIndex(classIndex: Int, row: Int, lane: Int) -> Int {
        (classIndex * Self.rowCount + row) * Self.laneCount + lane
    }

    private func softmaxSecond(_ first: Float32, _ second: Float32) -> Double {
        let maximum = max(first, second)
        let a = exp(Double(first - maximum))
        let b = exp(Double(second - maximum))
        return b / (a + b)
    }

    private func fittedX(points: [CGPoint], at y: Double) -> Double? {
        guard points.count >= 8 else { return nil }
        let count = Double(points.count)
        let sumY = points.reduce(0.0) { $0 + Double($1.y) }
        let sumX = points.reduce(0.0) { $0 + Double($1.x) }
        let sumYY = points.reduce(0.0) { $0 + Double($1.y * $1.y) }
        let sumYX = points.reduce(0.0) { $0 + Double($1.y * $1.x) }
        let denominator = count * sumYY - sumY * sumY
        guard abs(denominator) > 0.000_001 else { return nil }
        let slope = (count * sumYX - sumY * sumX) / denominator
        let intercept = (sumX - slope * sumY) / count
        let value = slope * y + intercept
        return value.isFinite ? value : nil
    }

    private func floatArray(from value: ORTValue, name: String) throws -> [Float32] {
        let data = try value.tensorData() as Data
        guard data.count % MemoryLayout<Float32>.stride == 0 else {
            throw LaneAIDetectorError.invalidOutput(name)
        }
        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float32.self))
        }
    }
}
