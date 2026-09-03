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
    @Published private(set) var trafficSignState = TrafficSignState()
    @Published private(set) var trafficSignStatus = "SIGN AI READY"

    var horizontalFieldOfViewDegrees: Double = 0

    private var totalFrames: UInt64 = 0
    private var lastPublishedAt = ProcessInfo.processInfo.systemUptime
    private var inferenceFrameCounter = 0
    private var laneFrameCounter = 1
    private var signFrameCounter = 0
    private let inferenceStride = 2
    private let laneStride = 2
    // Traffic signs persist for many frames. Running OCR/shape recognition at a
    // lower cadence keeps lane + lead latency low while still confirming signs quickly.
    private let signStride = 8
    private var lastVehicleSeenAt: TimeInterval = 0
    private var lastLaneSeenAt: TimeInterval = 0
    private let detector: VehicleDetector?
    private let distanceEstimator = DistanceEstimator()
    private let leadDistanceTracker = LeadDistanceTracker()
    private let laneDetector: LaneAIDetector?
    private let laneDepartureMonitor = LaneDepartureMonitor()
    private let trafficSignDetector = TrafficSignDetector()
    private let trafficSignTracker = TrafficSignStateTracker()
    private var latestLaneDetection: LaneDetection?

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
        signFrameCounter &+= 1

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var newDetections: [VehicleDetection]?
        var newInferenceMS: Double?
        var newLeadState: LeadDistanceState?
        var newLaneDetection: LaneDetection?
        var laneWasEvaluated = false
        var newLaneState: LaneDepartureState?
        var newTrafficSignState: TrafficSignState?
        var newTrafficSignStatus: String?

        if inferenceFrameCounter >= inferenceStride, let detector {
            inferenceFrameCounter = 0
            do {
                let result = try detector.detect(pixelBuffer: pixelBuffer)
                newDetections = result.detections.map { $0.markingLead(false) }
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
                if let lane {
                    lastLaneSeenAt = ProcessInfo.processInfo.systemUptime
                    latestLaneDetection = lane
                    newLaneDetection = lane
                    newLaneState = laneDepartureMonitor.update(with: lane)
                } else if ProcessInfo.processInfo.systemUptime - lastLaneSeenAt > 0.7 {
                    latestLaneDetection = nil
                    newLaneDetection = nil
                    newLaneState = laneDepartureMonitor.update(with: nil)
                } else {
                    laneWasEvaluated = false
                }
            } catch {
                newLaneDetection = nil
                newLaneState = laneDepartureMonitor.update(with: nil)
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    self?.laneStatus = "LANE MODEL ERROR: \(message)"
                }
            }
        }

        if signFrameCounter >= signStride {
            signFrameCounter = 0
            do {
                let observations = try trafficSignDetector.detect(pixelBuffer: pixelBuffer, timestamp: timestamp)
                var state = trafficSignTracker.state
                for observation in observations {
                    state = trafficSignTracker.ingest(observation)
                }
                newTrafficSignState = state

                if observations.isEmpty {
                    newTrafficSignStatus = "SIGN AI • SEARCH"
                } else {
                    let summary = observations.map { observation -> String in
                        switch observation.kind {
                        case .speedLimit(let value): return "LIMIT \(value)"
                        case .denseAreaStart: return "R420"
                        case .denseAreaEnd: return "R421"
                        }
                    }.joined(separator: " + ")
                    newTrafficSignStatus = "SIGN AI • \(summary)"
                }
            } catch {
                newTrafficSignStatus = "SIGN AI ERROR: \(error.localizedDescription)"
            }
        }

        if var measured = newDetections {
            if let lane = latestLaneDetection,
               let leadIndex = leadVehicleIndex(in: measured, lane: lane) {
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
                measured[leadIndex] = measured[leadIndex]
                    .markingLead(true)
                    .withDistance(tracked.distanceMeters)
                newLeadState = tracked
                lastVehicleSeenAt = ProcessInfo.processInfo.systemUptime
            } else if ProcessInfo.processInfo.systemUptime - lastVehicleSeenAt > 0.8 {
                leadDistanceTracker.reset()
                newLeadState = LeadDistanceState(
                    distanceMeters: nil,
                    closingSpeedMetersPerSecond: nil,
                    risk: .unavailable
                )
            }
            newDetections = measured
        }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublishMetrics = now - lastPublishedAt >= 0.25

        guard shouldPublishMetrics || newDetections != nil || laneWasEvaluated || newTrafficSignState != nil else { return }

        if shouldPublishMetrics { lastPublishedAt = now }
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
                if let newLeadState {
                    self.leadDistanceState = newLeadState
                    self.leadDistanceMeters = newLeadState.distanceMeters
                }
                self.detectorStatus = newDetections.isEmpty
                    ? "VEHICLE MODEL ACTIVE • NO VEHICLE"
                    : "VEHICLE MODEL ACTIVE • \(newDetections.count) VEHICLE(S)"
            }

            if let newInferenceMS { self.inferenceMS = newInferenceMS }

            if laneWasEvaluated {
                self.laneDetection = newLaneDetection
                if let newLaneState { self.laneDepartureState = newLaneState }

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

            if let newTrafficSignState { self.trafficSignState = newTrafficSignState }
            if let newTrafficSignStatus { self.trafficSignStatus = newTrafficSignStatus }
        }
    }

    /// Select only a vehicle whose road-contact point is inside the two
    /// detected ego-lane boundaries. No lane means no distance warning.
    private func leadVehicleIndex(
        in detections: [VehicleDetection],
        lane: LaneDetection
    ) -> Int? {
        let candidates = detections.indices.filter { index in
            let box = detections[index].boundingBox
            let contactY = 1.0 - Double(box.minY)
            guard let leftX = fittedLaneX(lane.leftPoints, at: contactY),
                  let rightX = fittedLaneX(lane.rightPoints, at: contactY),
                  rightX > leftX else { return false }
            let contactX = Double(box.midX)
            return contactX >= leftX && contactX <= rightX
        }

        return candidates.max { lhs, rhs in
            let a = detections[lhs].boundingBox
            let b = detections[rhs].boundingBox
            let aScore = (1.0 - Double(a.minY)) + Double(a.width * a.height)
            let bScore = (1.0 - Double(b.minY)) + Double(b.width * b.height)
            return aScore < bScore
        }
    }

    private func fittedLaneX(_ points: [CGPoint], at y: Double) -> Double? {
        guard points.count >= 6 else { return nil }
        let count = Double(points.count)
        let sumY = points.reduce(0.0) { $0 + Double($1.y) }
        let sumX = points.reduce(0.0) { $0 + Double($1.x) }
        let sumYY = points.reduce(0.0) { $0 + Double($1.y * $1.y) }
        let sumYX = points.reduce(0.0) { $0 + Double($1.y * $1.x) }
        let denominator = count * sumYY - sumY * sumY
        guard abs(denominator) > 0.000_001 else { return nil }
        let slope = (count * sumYX - sumY * sumX) / denominator
        let intercept = (sumX - slope * sumY) / count
        let x = slope * y + intercept
        return x.isFinite ? x : nil
    }
}
