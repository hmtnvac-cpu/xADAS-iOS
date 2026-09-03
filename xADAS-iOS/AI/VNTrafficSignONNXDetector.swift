import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import OnnxRuntimeBindings

struct VNDetectedTrafficSign {
    let code: String
    let confidence: Float
    let boundingBox: CGRect
}

enum VNTrafficSignONNXError: LocalizedError {
    case modelMissing
    case labelsMissing
    case invalidFrame
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "VTSR ONNX model is not bundled."
        case .labelsMissing: return "VTSR label mapping is not bundled."
        case .invalidFrame: return "Could not prepare traffic-sign frame."
        case .invalidOutput: return "VTSR returned an unexpected output tensor."
        }
    }
}

/// YOLOv8n Vietnamese traffic-sign detector running fully on-device through
/// ONNX Runtime. The model is the VTSR 56-class Vietnamese traffic-sign model.
final class VNTrafficSignONNXDetector {
    private static let inputSize = 640
    private let environment: ORTEnv
    private let session: ORTSession
    private let labels: [String]
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "VTSRInt8", withExtension: "onnx") else {
            throw VNTrafficSignONNXError.modelMissing
        }
        guard let labelURL = Bundle.main.url(forResource: "VTSRLabelMapping", withExtension: "json") else {
            throw VNTrafficSignONNXError.labelsMissing
        }

        labels = try Self.loadLabels(url: labelURL)
        guard !labels.isEmpty else { throw VNTrafficSignONNXError.labelsMissing }

        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
    }

    func detect(pixelBuffer: CVPixelBuffer, confidenceThreshold: Float = 0.24) throws -> [VNDetectedTrafficSign] {
        let input = try makeInput(pixelBuffer: pixelBuffer)
        let data = input.withUnsafeBufferPointer { Data(buffer: $0) }
        let value = try ORTValue(
            tensorData: NSMutableData(data: data),
            elementType: .float,
            shape: [1, 3, NSNumber(value: Self.inputSize), NSNumber(value: Self.inputSize)]
        )

        let outputs = try session.run(
            withInputs: ["images": value],
            outputNames: ["output0"],
            runOptions: nil
        )
        guard let output = outputs["output0"] else { throw VNTrafficSignONNXError.invalidOutput }
        let floats = try floatArray(from: output)

        let channelCount = labels.count + 4
        guard channelCount > 4, floats.count % channelCount == 0 else {
            throw VNTrafficSignONNXError.invalidOutput
        }
        let candidateCount = floats.count / channelCount
        guard candidateCount >= 100 else { throw VNTrafficSignONNXError.invalidOutput }

        var raw: [VNDetectedTrafficSign] = []
        raw.reserveCapacity(32)

        // Ultralytics YOLOv8 ONNX output is normally [1, 4+C, N].
        for candidate in 0..<candidateCount {
            let cx = floats[0 * candidateCount + candidate]
            let cy = floats[1 * candidateCount + candidate]
            let w = floats[2 * candidateCount + candidate]
            let h = floats[3 * candidateCount + candidate]

            var bestClass = -1
            var bestScore: Float = 0
            for classIndex in 0..<labels.count {
                let score = floats[(4 + classIndex) * candidateCount + candidate]
                if score > bestScore {
                    bestScore = score
                    bestClass = classIndex
                }
            }

            guard bestClass >= 0, bestScore >= confidenceThreshold,
                  cx.isFinite, cy.isFinite, w.isFinite, h.isFinite,
                  w > 2, h > 2 else { continue }

            let x = max(0, min(1, Double(cx - w / 2) / Double(Self.inputSize)))
            let yTop = max(0, min(1, Double(cy - h / 2) / Double(Self.inputSize)))
            let width = max(0, min(1 - x, Double(w) / Double(Self.inputSize)))
            let height = max(0, min(1 - yTop, Double(h) / Double(Self.inputSize)))
            guard width > 0.006, height > 0.006 else { continue }

            // Vision/CoreImage normalized coordinates use bottom-left origin.
            let box = CGRect(x: x, y: 1 - yTop - height, width: width, height: height)
            raw.append(VNDetectedTrafficSign(code: labels[bestClass], confidence: bestScore, boundingBox: box))
        }

        return nonMaximumSuppression(raw, iouThreshold: 0.45, maxDetections: 30)
    }

    private func makeInput(pixelBuffer: CVPixelBuffer) throws -> [Float32] {
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else { throw VNTrafficSignONNXError.invalidFrame }

        var prepared: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.inputSize,
            Self.inputSize,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &prepared
        )
        guard status == kCVReturnSuccess, let prepared else { throw VNTrafficSignONNXError.invalidFrame }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let sx = CGFloat(Self.inputSize) / sourceWidth
        let sy = CGFloat(Self.inputSize) / sourceHeight
        let resized = source.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(
            resized,
            to: prepared,
            bounds: CGRect(x: 0, y: 0, width: Self.inputSize, height: Self.inputSize),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        CVPixelBufferLockBaseAddress(prepared, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(prepared, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(prepared) else { throw VNTrafficSignONNXError.invalidFrame }

        let rowBytes = CVPixelBufferGetBytesPerRow(prepared)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let plane = Self.inputSize * Self.inputSize
        var tensor = [Float32](repeating: 0, count: plane * 3)

        for y in 0..<Self.inputSize {
            let row = bytes.advanced(by: y * rowBytes)
            for x in 0..<Self.inputSize {
                let p = row.advanced(by: x * 4)
                let i = y * Self.inputSize + x
                tensor[i] = Float32(p[2]) / 255.0
                tensor[plane + i] = Float32(p[1]) / 255.0
                tensor[2 * plane + i] = Float32(p[0]) / 255.0
            }
        }
        return tensor
    }

    private func floatArray(from value: ORTValue) throws -> [Float32] {
        let data = try value.tensorData() as Data
        guard data.count % MemoryLayout<Float32>.stride == 0 else {
            throw VNTrafficSignONNXError.invalidOutput
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
    }

    private func nonMaximumSuppression(
        _ detections: [VNDetectedTrafficSign],
        iouThreshold: Double,
        maxDetections: Int
    ) -> [VNDetectedTrafficSign] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [VNDetectedTrafficSign] = []
        for detection in sorted {
            let overlaps = kept.contains { existing in
                existing.code == detection.code && iou(existing.boundingBox, detection.boundingBox) > iouThreshold
            }
            if !overlaps { kept.append(detection) }
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

    private static func loadLabels(url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)

        if let array = json as? [String] { return array }
        if let dictionary = json as? [String: Any] {
            let numericKeys = dictionary.keys.compactMap(Int.init).sorted()
            if !numericKeys.isEmpty {
                return numericKeys.compactMap { index in
                    let value = dictionary[String(index)]
                    if let string = value as? String { return string }
                    if let object = value as? [String: Any] {
                        return (object["code"] as? String)
                            ?? (object["label"] as? String)
                            ?? (object["name"] as? String)
                    }
                    return nil
                }
            }

            if let names = dictionary["names"] as? [String] { return names }
            if let names = dictionary["names"] as? [String: Any] {
                return names.keys.compactMap(Int.init).sorted().compactMap { index in
                    names[String(index)] as? String
                }
            }
        }
        throw VNTrafficSignONNXError.labelsMissing
    }
}
