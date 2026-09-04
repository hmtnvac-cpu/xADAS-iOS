import CoreFoundation
import CoreImage
import CoreML
import CoreVideo
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
        (2, "car"), (3, "motorbike"), (5, "bus"), (7, "truck")
    ]
    private let request: VNCoreMLRequest
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var detectionPass: UInt64 = 0

    init() throws {
        guard let compiledURL = Bundle.main.url(forResource: "YOLOv3TinyInt8LUT", withExtension: "mlmodelc") else {
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
        detectionPass &+= 1

        // Road-focused sliced inference. At 55-70 m a passenger car can occupy
        // only a few percent of a wide 70mai frame. Resizing the whole frame to
        // a detector input destroys those pixels. Magnify the forward road ROI
        // on 3/4 passes, then periodically scan a wider ROI for cut-ins.
        let mode: CropMode
        switch detectionPass % 4 {
        case 0: mode = .wide
        default: mode = .far
        }
        let prepared = makeLeadVehicleCrop(from: pixelBuffer, mode: mode)

        let handler = VNImageRequestHandler(
            cvPixelBuffer: prepared.pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try handler.perform([request])

        let elapsedMS = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let observations = request.results ?? []
        let recognizedObjects = observations.compactMap { $0 as? VNRecognizedObjectObservation }
        let confidenceFloor: Float = mode == .far ? 0.055 : 0.085

        var vehicles = recognizedObjects.compactMap { observation -> VehicleDetection? in
            guard let best = observation.labels.first,
                  best.confidence >= confidenceFloor,
                  vehicleLabels.contains(best.identifier.lowercased()) else { return nil }
            return VehicleDetection(
                label: best.identifier,
                confidence: best.confidence,
                boundingBox: observation.boundingBox
            )
        }

        if vehicles.isEmpty {
            vehicles = decodeFeatureArrays(from: observations, confidenceFloor: Double(confidenceFloor))
        }

        vehicles = vehicles.map { map($0, from: prepared.roi) }
            .filter { plausibleRoadVehicle($0, mode: mode) }

        guard !vehicles.isEmpty else { return ([], elapsedMS) }

        if let leadIndex = selectLeadIndex(in: vehicles) {
            vehicles[leadIndex] = vehicles[leadIndex].markingLead(true)
        }
        return (vehicles, elapsedMS)
    }

    private func decodeFeatureArrays(
        from observations: [VNObservation],
        confidenceFloor: Double
    ) -> [VehicleDetection] {
        let features = observations.compactMap { $0 as? VNCoreMLFeatureValueObservation }
        guard let confidence = features.first(where: { $0.featureName == "confidence" })?.featureValue.multiArrayValue,
              let coordinates = features.first(where: { $0.featureName == "coordinates" })?.featureValue.multiArrayValue,
              confidence.shape.count == 2,
              coordinates.shape.count == 2 else { return [] }

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
                if score >= confidenceFloor, score > (bestClass?.confidence ?? 0) {
                    bestClass = (vehicleClass.label, score)
                }
            }
            guard let bestClass else { continue }

            let centerX = value(coordinates, row, 0)
            let centerYFromTop = value(coordinates, row, 1)
            let width = value(coordinates, row, 2)
            let height = value(coordinates, row, 3)
            guard centerX.isFinite, centerYFromTop.isFinite, width.isFinite, height.isFinite,
                  width > 0, height > 0 else { continue }

            let minX = centerX - width / 2
            let minY = 1 - (centerYFromTop + height / 2)
            let box = CGRect(
                x: max(0, min(minX, 1)),
                y: max(0, min(minY, 1)),
                width: max(0, min(width, 1)),
                height: max(0, min(height, 1))
            ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

            // Far-road sliced mode intentionally allows much smaller objects.
            guard !box.isNull, box.width > 0.004, box.height > 0.004 else { continue }
            detections.append(VehicleDetection(
                label: bestClass.label,
                confidence: Float(bestClass.confidence),
                boundingBox: box
            ))
        }
        return detections
    }

    private enum CropMode { case far, wide }

    private func makeLeadVehicleCrop(
        from pixelBuffer: CVPixelBuffer,
        mode: CropMode
    ) -> (pixelBuffer: CVPixelBuffer, roi: CGRect) {
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard sourceWidth > 0, sourceHeight > 0 else {
            return (pixelBuffer, CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let defaults = UserDefaults.standard
        let savedCenter = defaults.double(forKey: DistanceEstimator.cameraCenterXKey)
        let center = CGFloat(savedCenter > 0.1 ? savedCenter : 0.5)

        let roi: CGRect
        switch mode {
        case .far:
            // Focus on the vanishing-point / forward-road region. This gives a
            // distant vehicle roughly 2-2.5x more detector pixels than the old
            // 58%-wide ROI and substantially more than a full-frame pass.
            let width: CGFloat = 0.40
            roi = CGRect(
                x: min(max(center - width / 2, 0), 1 - width),
                y: 0.25,
                width: width,
                height: 0.52
            )
        case .wide:
            let savedWidth = defaults.double(forKey: DistanceEstimator.vehicleROIWidthKey)
            let width = CGFloat(min(max(savedWidth, 0.56), 0.76))
            roi = CGRect(
                x: min(max(center - width / 2, 0), 1 - width),
                y: 0.08,
                width: width,
                height: 0.80
            )
        }

        let outputWidth = 640
        let outputHeight = 480
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputWidth,
            outputHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let output else {
            return (pixelBuffer, CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let crop = CGRect(
            x: roi.minX * sourceWidth,
            y: roi.minY * sourceHeight,
            width: roi.width * sourceWidth,
            height: roi.height * sourceHeight
        )
        let source = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(outputWidth) / crop.width,
                y: CGFloat(outputHeight) / crop.height
            ))
        ciContext.render(
            source,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return (output, roi)
    }

    private func plausibleRoadVehicle(_ detection: VehicleDetection, mode: CropMode) -> Bool {
        let box = detection.boundingBox
        let savedCenter = CGFloat(UserDefaults.standard.double(forKey: DistanceEstimator.cameraCenterXKey))
        let cameraCenter = savedCenter > 0.1 ? savedCenter : 0.5
        let centerDistance = abs(box.midX - cameraCenter)
        guard centerDistance <= (mode == .far ? 0.24 : 0.34) else { return false }
        // Reject objects too high in the sky or implausibly below the visible road.
        let contactFromTop = 1.0 - box.minY
        return contactFromTop >= 0.30 && contactFromTop <= 0.96
    }

    private func map(_ detection: VehicleDetection, from roi: CGRect) -> VehicleDetection {
        let box = detection.boundingBox
        let mapped = CGRect(
            x: roi.minX + box.minX * roi.width,
            y: roi.minY + box.minY * roi.height,
            width: box.width * roi.width,
            height: box.height * roi.height
        )
        return VehicleDetection(
            label: detection.label,
            confidence: detection.confidence,
            boundingBox: mapped,
            isLead: detection.isLead,
            distanceMeters: detection.distanceMeters
        )
    }

    private func selectLeadIndex(in detections: [VehicleDetection]) -> Int? {
        let calibratedCenter = CGFloat(UserDefaults.standard.double(forKey: DistanceEstimator.cameraCenterXKey))
        let cameraCenter = calibratedCenter > 0.1 ? calibratedCenter : 0.5
        let candidates = detections.indices.filter { index in
            let box = detections[index].boundingBox
            return abs(box.midX - cameraCenter) <= 0.28 && box.maxY >= 0.12
        }
        return candidates.min { lhs, rhs in
            leadScore(detections[lhs]) < leadScore(detections[rhs])
        }
    }

    private func leadScore(_ detection: VehicleDetection) -> CGFloat {
        let box = detection.boundingBox
        let savedCenter = CGFloat(UserDefaults.standard.double(forKey: DistanceEstimator.cameraCenterXKey))
        let cameraCenter = savedCenter > 0.1 ? savedCenter : 0.5
        let centerPenalty = abs(box.midX - cameraCenter) * 2.5
        let bottomPenalty = box.minY
        let sizeBonus = box.width * box.height * 0.7
        return centerPenalty + bottomPenalty - sizeBonus
    }
}
