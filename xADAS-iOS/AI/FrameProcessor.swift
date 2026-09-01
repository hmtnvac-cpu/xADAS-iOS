import AVFoundation
import Combine
import CoreMedia
import CoreVideo

final class FrameProcessor: ObservableObject {
    @Published private(set) var processedFrames: UInt64 = 0
    @Published private(set) var frameWidth: Int = 0
    @Published private(set) var frameHeight: Int = 0
    @Published private(set) var pipelineStatus = "FRAME PIPELINE READY"
    @Published private(set) var detections: [VehicleDetection] = []
    @Published private(set) var inferenceMS: Double = 0
    @Published private(set) var detectorStatus = "MODEL NOT LOADED"

    private var totalFrames: UInt64 = 0
    private var lastPublishedAt = ProcessInfo.processInfo.systemUptime
    private var inferenceFrameCounter = 0
    private let inferenceStride = 2
    private let detector: VehicleDetector?

    init() {
        do {
            detector = try VehicleDetector()
            detectorStatus = "VEHICLE MODEL READY"
        } catch {
            detector = nil
            detectorStatus = error.localizedDescription
        }
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        totalFrames &+= 1
        inferenceFrameCounter &+= 1

        var newDetections: [VehicleDetection]?
        var newInferenceMS: Double?

        if inferenceFrameCounter >= inferenceStride, let detector {
            inferenceFrameCounter = 0
            do {
                let result = try detector.detect(pixelBuffer: pixelBuffer)
                newDetections = result.detections
                newInferenceMS = result.inferenceMS
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.detectorStatus = "MODEL ERROR: \(message)"
                }
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublishMetrics = now - lastPublishedAt >= 0.25

        guard shouldPublishMetrics || newDetections != nil else { return }

        if shouldPublishMetrics {
            lastPublishedAt = now
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let count = totalFrames

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if shouldPublishMetrics {
                self.frameWidth = width
                self.frameHeight = height
                self.processedFrames = count
                self.pipelineStatus = "FRAME PIPELINE ACTIVE"
            }

            if let newDetections {
                self.detections = newDetections
                self.detectorStatus = newDetections.isEmpty
                    ? "VEHICLE MODEL ACTIVE • NO VEHICLE"
                    : "VEHICLE MODEL ACTIVE • \(newDetections.count) VEHICLE(S)"
            }

            if let newInferenceMS {
                self.inferenceMS = newInferenceMS
            }
        }
    }
}
