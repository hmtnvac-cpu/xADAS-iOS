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
    @Published private(set) var leadDistanceMeters: Double?
    @Published private(set) var leadDistanceState = LeadDistanceState(
        distanceMeters: nil,
        closingSpeedMetersPerSecond: nil,
        risk: .unavailable
    )
    @Published private(set) var laneDetection: LaneDetection?
    @Published private(set) var laneDepartureState: LaneDepartureState = .unavailable
    @Published private(set) var laneStatus = "LANE MODEL LOADING"

    var horizontalFieldOfViewDegrees: Double = 0

    private var totalFrames: UInt64 = 0
    private var lastPublishedAt = ProcessInfo.processInfo.systemUptime
    private var inferenceFrameCounter = 0
    private var laneFrameCounter = 0
    private let inferenceStride = 2
    private let laneStride = 5
    private let detector: VehicleDetector?
    private let distanceEstimator = DistanceEstimator()
    private let leadDistanceTracker = LeadDistanceTracker()
    private let laneDetector: LaneAIDetector?
    private let laneDepartureMonitor = LaneDepartureMonitor()

    init() {
        do {
            detector = try VehicleDetector()
            detectorStatus = "VEHICLE MODEL READY"
        } catch {
            detector = nil
            detectorStatus = error.localizedDescription
        }

        do {
            laneDetector = try LaneAIDetector()
            laneStatus = "UFLD V2 LANE MODEL READY"
        } catch {
            laneDetector = nil
            laneStatus = error.localizedDescription
        }
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sampleTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let timestamp = sampleTime.isFinite ? sampleTime : ProcessInfo.processInfo.systemUptime
        process(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        totalFrames &+= 1
        inferenceFrameCounter &+= 1
        laneFrameCounter &+= 1

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var newDetections: [VehicleDetection]?
        var newInferenceMS: Double?
        var newLeadState: LeadDistanceState?
        var newLaneDetection: LaneDetection?
        var laneWasEvaluated = false
        var newLaneState: LaneDepartureState?

        if inferenceFrameCounter >= inferenceStride, let detector {
            inferenceFrameCounter = 0
            do {
                let result = try detector.detect(pixelBuffer: pixelBuffer)
                var measured = result.detections

                if let leadIndex = measured.firstIndex(where: { $0.isLead }) {
                    let leadBox = measured[leadIndex].boundingBox
                    let rawDistance = distanceEstimator.estimate(
                        for: leadBox,
                        frameWidth: width,
                        frameHeight: height,
                        horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees
                    )
                    let tracked = leadDistanceTracker.update(
                        rawDistance: rawDistance,
                        leadBox: leadBox,
                        timestamp: timestamp
                    )
                    measured[leadIndex] = measured[leadIndex].withDistance(tracked.distanceMeters)
                    newLeadState = tracked
                } else {
                    leadDistanceTracker.reset()
                    newLeadState = LeadDistanceState(
                        distanceMeters: nil,
                        closingSpeedMetersPerSecond: nil,
                        risk: .unavailable
                    )
                }

                newDetections = measured
                newInferenceMS = result.inferenceMS
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.detectorStatus = "MODEL ERROR: \(message)"
                }
            }
        }

        if laneFrameCounter >= laneStride, let laneDetector {
            laneFrameCounter = 0
            laneWasEvaluated = true
            do {
                let lane = try laneDetector.detect(pixelBuffer: pixelBuffer)
                newLaneDetection = lane
                newLaneState = laneDepartureMonitor.update(with: lane)
            } catch {
                newLaneDetection = nil
                newLaneState = laneDepartureMonitor.update(with: nil)
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.laneStatus = "LANE MODEL ERROR: \(message)"
                }
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublishMetrics = now - lastPublishedAt >= 0.25

        guard shouldPublishMetrics || newDetections != nil || laneWasEvaluated else { return }

        if shouldPublishMetrics {
            lastPublishedAt = now
        }

        let count = totalFrames

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            if shouldPublishMetrics {
                self.frameWidth = width
                self.frameHeight = height
                self.processedFrames = count
                self.pipelineStatus = "70MAI FRAME PIPELINE ACTIVE"
            }

            if let newDetections {
                self.detections = newDetections
                if let newLeadState {
                    self.leadDistanceState = newLeadState
                    self.leadDistanceMeters = newLeadState.distanceMeters
                }
                self.detectorStatus = newDetections.isEmpty
                    ? "VEHICLE MODEL ACTIVE • NO VEHICLE"
                    : "VEHICLE MODEL ACTIVE • \(newDetections.count) VEHICLE(S)"
            }

            if let newInferenceMS {
                self.inferenceMS = newInferenceMS
            }

            if laneWasEvaluated {
                self.laneDetection = newLaneDetection
                if let newLaneState {
                    self.laneDepartureState = newLaneState
                }

                if let lane = newLaneDetection {
                    self.laneStatus = String(
                        format: "LANE ACTIVE • %.0f%% • OFFSET %+.2f",
                        lane.confidence * 100,
                        lane.normalizedCenterOffset
                    )
                } else {
                    self.laneStatus = "LANE SEARCHING"
                }
            }
        }
    }
}
