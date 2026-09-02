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
    private let vehicleClassIndexes: [(index: Int, label: String)] = [
        (2, "car"),
        (3, "motorbike"),
        (5, "bus"),
        (7, "truck")
    ]
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
        let observations = request.results ?? []
        let recognizedObjects = observations.compactMap { $0 as? VNRecognizedObjectObservation }

        var vehicles = recognizedObjects.compactMap { observation -> VehicleDetection? in
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

        // Apple's YOLOv3 Tiny model exposes `confidence` and `coordinates`
        // multi-arrays. Vision does not always wrap these as recognized-object
        // observations, so decode the model's real output instead of silently
        // returning an empty vehicle list.
        if vehicles.isEmpty {
            vehicles = decodeFeatureArrays(from: observations)
        }

        guard !vehicles.isEmpty else {
            return ([], elapsedMS)
        }

        if let leadIndex = selectLeadIndex(in: vehicles) {
            vehicles[leadIndex] = vehicles[leadIndex].markingLead(true)
        }

        return (vehicles, elapsedMS)
    }

    private func decodeFeatureArrays(from observations: [VNObservation]) -> [VehicleDetection] {
        let features = observations.compactMap { $0 as? VNCoreMLFeatureValueObservation }
        guard let confidence = features.first(where: { $0.featureName == "confidence" })?
            .featureValue.multiArrayValue,
              let coordinates = features.first(where: { $0.featureName == "coordinates" })?
            .featureValue.multiArrayValue,
              confidence.shape.count == 2,
              coordinates.shape.count == 2 else {
            return []
        }

        let boxCount = confidence.shape[0].intValue
        let classCount = confidence.shape[1].intValue
        let coordinateCount = coordinates.shape[1].intValue
        guard boxCount > 0, classCount >= 8, coordinateCount >= 4 else { return [] }

        func value(_ array: MLMultiArray, _ row: Int, _ column: Int) -> Double {
            array[[NSNumber(value: row), NSNumber(value: column)]].doubleValue
        }

        var detections: [VehicleDetection] = []
        detections.reserveCapacity(boxCount)

        for row in 0..<boxCount {
            var bestClass: (label: String, confidence: Double)?
            for vehicleClass in vehicleClassIndexes where vehicleClass.index < classCount {
                let score = value(confidence, row, vehicleClass.index)
                if score >= 0.18, score > (bestClass?.confidence ?? 0) {
                    bestClass = (vehicleClass.label, score)
                }
            }

            guard let bestClass else { continue }

            let centerX = value(coordinates, row, 0)
            let centerYFromTop = value(coordinates, row, 1)
            let width = value(coordinates, row, 2)
            let height = value(coordinates, row, 3)
            guard centerX.isFinite,
                  centerYFromTop.isFinite,
                  width.isFinite,
                  height.isFinite,
                  width > 0,
                  height > 0 else { continue }

            // YOLO uses a top-left image origin. VehicleDetection follows
            // Vision's normalized bottom-left coordinate convention.
            let minX = centerX - width / 2
            let minY = 1 - (centerYFromTop + height / 2)
            let box = CGRect(
                x: max(0, min(minX, 1)),
                y: max(0, min(minY, 1)),
                width: max(0, min(width, 1)),
                height: max(0, min(height, 1))
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

            guard !box.isNull, box.width > 0.01, box.height > 0.01 else { continue }

            detections.append(
                VehicleDetection(
                    label: bestClass.label,
                    confidence: Float(bestClass.confidence),
                    boundingBox: box
                )
            )
        }

        return detections
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
