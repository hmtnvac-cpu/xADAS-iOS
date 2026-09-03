import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import OnnxRuntimeBindings

struct VN82Detection {
    let classID: Int
    let confidence: Float
    let boundingBox: CGRect
}

enum VNTrafficSign82Error: LocalizedError {
    case modelMissing
    case invalidFrame
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "VN82 traffic-sign model is not bundled."
        case .invalidFrame: return "Could not prepare traffic-sign frame."
        case .invalidOutput: return "VN82 traffic-sign model returned an unexpected tensor."
        }
    }
}

final class VNTrafficSign82Detector {
    static let inputSize = 640
    static let classCount = 82

    private let environment: ORTEnv
    private let session: ORTSession
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "VNTrafficSign82", withExtension: "onnx") else {
            throw VNTrafficSign82Error.modelMissing
        }

        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
    }

    func detect(pixelBuffer: CVPixelBuffer, confidenceThreshold: Float = 0.24) throws -> [VN82Detection] {
        let prepared = try makeInput(pixelBuffer: pixelBuffer)
        let inputData = prepared.tensor.withUnsafeBufferPointer { Data(buffer: $0) }
        let inputValue = try ORTValue(
            tensorData: NSMutableData(data: inputData),
            elementType: .float,
            shape: [
                NSNumber(value: 1),
                NSNumber(value: 3),
                NSNumber(value: Self.inputSize),
                NSNumber(value: Self.inputSize)
            ]
        )

        let outputs = try session.run(
            withInputs: ["images": inputValue],
            outputNames: ["output0"],
            runOptions: nil
        )
        guard let output = outputs["output0"] else { throw VNTrafficSign82Error.invalidOutput }
        let values = try floatArray(from: output)

        let featureCount = Self.classCount + 4
        guard values.count % featureCount == 0 else { throw VNTrafficSign82Error.invalidOutput }
        let candidateCount = values.count / featureCount
        guard candidateCount >= 100 else { throw VNTrafficSign82Error.invalidOutput }

        var raw: [VN82Detection] = []
        raw.reserveCapacity(40)

        for candidate in 0..<candidateCount {
            let cx = values[candidate]
            let cy = values[candidateCount + candidate]
            let w = values[2 * candidateCount + candidate]
            let h = values[3 * candidateCount + candidate]

            var bestClass = -1
            var bestScore: Float = 0
            for classID in 0..<Self.classCount {
                let score = values[(4 + classID) * candidateCount + candidate]
                if score > bestScore {
                    bestScore = score
                    bestClass = classID
                }
            }

            guard bestClass >= 0,
                  bestScore >= confidenceThreshold,
                  cx.isFinite, cy.isFinite, w.isFinite, h.isFinite,
                  w > 2, h > 2 else { continue }

            let left = Double(cx - w / 2)
            let top = Double(cy - h / 2)
            let right = Double(cx + w / 2)
            let bottom = Double(cy + h / 2)

            let sourceLeft = (left - prepared.padX) / prepared.scale
            let sourceTop = (top - prepared.padY) / prepared.scale
            let sourceRight = (right - prepared.padX) / prepared.scale
            let sourceBottom = (bottom - prepared.padY) / prepared.scale

            let x0 = min(max(sourceLeft / prepared.sourceWidth, 0), 1)
            let y0Top = min(max(sourceTop / prepared.sourceHeight, 0), 1)
            let x1 = min(max(sourceRight / prepared.sourceWidth, 0), 1)
            let y1Bottom = min(max(sourceBottom / prepared.sourceHeight, 0), 1)
            let width = x1 - x0
            let height = y1Bottom - y0Top
            guard width > 0.004, height > 0.004 else { continue }

            let visionBox = CGRect(
                x: CGFloat(x0),
                y: CGFloat(1.0 - y1Bottom),
                width: CGFloat(width),
                height: CGFloat(height)
            )
            raw.append(VN82Detection(classID: bestClass, confidence: bestScore, boundingBox: visionBox))
        }

        return nonMaximumSuppression(raw, iouThreshold: 0.45, maxDetections: 24)
    }

    private struct PreparedInput {
        let tensor: [Float32]
        let scale: Double
        let padX: Double
        let padY: Double
        let sourceWidth: Double
        let sourceHeight: Double
    }

    private func makeInput(pixelBuffer: CVPixelBuffer) throws -> PreparedInput {
        let sourceWidth = Double(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = Double(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else { throw VNTrafficSign82Error.invalidFrame }

        let scale = min(Double(Self.inputSize) / sourceWidth, Double(Self.inputSize) / sourceHeight)
        let resizedWidth = sourceWidth * scale
        let resizedHeight = sourceHeight * scale
        let padX = (Double(Self.inputSize) - resizedWidth) / 2.0
        let padY = (Double(Self.inputSize) - resizedHeight) / 2.0

        var preparedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.inputSize,
            Self.inputSize,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &preparedBuffer
        )
        guard status == kCVReturnSuccess, let preparedBuffer else {
            throw VNTrafficSign82Error.invalidFrame
        }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let resized = source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(scale),
            y: CGFloat(scale)
        )).transformed(by: CGAffineTransform(
            translationX: CGFloat(padX),
            y: CGFloat(padY)
        ))

        let gray = CIImage(color: CIColor(
            red: CGFloat(114.0 / 255.0),
            green: CGFloat(114.0 / 255.0),
            blue: CGFloat(114.0 / 255.0)
        )).cropped(to: CGRect(x: 0, y: 0, width: Self.inputSize, height: Self.inputSize))
        let composed = resized.composited(over: gray)

        ciContext.render(
            composed,
            to: preparedBuffer,
            bounds: CGRect(x: 0, y: 0, width: Self.inputSize, height: Self.inputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        CVPixelBufferLockBaseAddress(preparedBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(preparedBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(preparedBuffer) else {
            throw VNTrafficSign82Error.invalidFrame
        }

        let rowBytes = CVPixelBufferGetBytesPerRow(preparedBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let plane = Self.inputSize * Self.inputSize
        var tensor = [Float32](repeating: 0, count: plane * 3)

        for y in 0..<Self.inputSize {
            let row = bytes.advanced(by: y * rowBytes)
            for x in 0..<Self.inputSize {
                let pixel = row.advanced(by: x * 4)
                let index = y * Self.inputSize + x
                tensor[index] = Float32(pixel[2]) / 255.0
                tensor[plane + index] = Float32(pixel[1]) / 255.0
                tensor[2 * plane + index] = Float32(pixel[0]) / 255.0
            }
        }

        return PreparedInput(
            tensor: tensor,
            scale: scale,
            padX: padX,
            padY: padY,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight
        )
    }

    private func floatArray(from value: ORTValue) throws -> [Float32] {
        let data = try value.tensorData() as Data
        guard data.count % MemoryLayout<Float32>.stride == 0 else {
            throw VNTrafficSign82Error.invalidOutput
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    private func nonMaximumSuppression(
        _ detections: [VN82Detection],
        iouThreshold: Double,
        maxDetections: Int
    ) -> [VN82Detection] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [VN82Detection] = []
        for detection in sorted {
            let suppressed = kept.contains { existing in
                existing.classID == detection.classID && iou(existing.boundingBox, detection.boundingBox) > iouThreshold
            }
            if !suppressed { kept.append(detection) }
            if kept.count >= maxDetections { break }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let inter = Double(intersection.width * intersection.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }
}
