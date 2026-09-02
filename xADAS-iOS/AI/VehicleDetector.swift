import CoreFoundation
import CoreML
import ImageIO
import Vision

final class VehicleDetector {
    enum DetectorError: LocalizedError {
        case modelNotFound
        case modelLoadFailed

        var errorDescription: String? {
            switch self {
            case .modelNotFound:
                return "YOLOv3TinyInt8LUT.mlmodel is not bundled with the app."
            case .modelLoadFailed:
                return "Unable to load the Core ML vehicle detector."
            }
        }
    }

    private let vehicleLabels: Set<String> = ["car", "truck", "bus", "motorbike", "motorcycle"]
    private let request: VNCoreMLRequest

    init() throws {
        guard let compiledURL = Bundle.main.url(
            forResource: "YOLOv3TinyInt8LUT",
            withExtension: "mlmodelc"
        ) else {
            throw DetectorError.modelNotFound
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        let mlModel: MLModel
        do {
            mlModel = try MLModel(contentsOf: compiledURL, configuration: configuration)
        } catch {
            throw DetectorError.modelLoadFailed
        }

        let visionModel = try VNCoreMLModel(for: mlModel)
        request = VNCoreMLRequest(model: visionModel)
        request.imageCropAndScaleOption = .scaleFill
    }

    func detect(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up
    ) throws -> (detections: [VehicleDetection], inferenceMS: Double) {
        let started = CFAbsoluteTimeGetCurrent()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )

        try handler.perform([request])

        let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let observations = request.results as? [VNRecognizedObjectObservation] ?? []

        var vehicles = observations.compactMap { observation -> VehicleDetection? in
            guard let best = observation.labels.first,
                  best.confidence >= 0.18,
                  vehicleLabels.contains(best.identifier.lowercased()) else {
                return nil
            }

            return VehicleDetection(
                label: best.identifier,
                confidence: best.confidence,
                boundingBox: observation.boundingBox
            )
        }

        guard !vehicles.isEmpty else {
            return ([], elapsedMS)
        }

        if let leadIndex = selectLeadIndex(in: vehicles) {
            vehicles[leadIndex] = vehicles[leadIndex].markingLead(true)
        }

        return (vehicles, elapsedMS)
    }

    private func selectLeadIndex(in detections: [VehicleDetection]) -> Int? {
        let candidates = detections.indices.filter { index in
            let box = detections[index].boundingBox
            let centerDistance = abs(box.midX - 0.5)

            // Keep the lead candidate inside a broad forward-driving corridor.
            return centerDistance <= 0.28 && box.maxY >= 0.12
        }

        return candidates.min { lhs, rhs in
            leadScore(detections[lhs]) < leadScore(detections[rhs])
        }
    }

    private func leadScore(_ detection: VehicleDetection) -> CGFloat {
        let box = detection.boundingBox
        let centerPenalty = abs(box.midX - 0.5) * 2.5
        let bottomPenalty = box.minY
        let sizeBonus = box.width * box.height * 0.7
        return centerPenalty + bottomPenalty - sizeBonus
    }
}
