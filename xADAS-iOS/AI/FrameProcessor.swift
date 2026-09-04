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
    @Published private(set) var leadDistanceState = LeadDistanceState(distanceMeters: nil, closingSpeedMetersPerSecond: nil, risk: .unavailable)
    @Published private(set) var laneDetection: LaneDetection?
    @Published private(set) var laneDepartureState: LaneDepartureState = .unavailable
    @Published private(set) var laneStatus = "LANE MODEL LOADING"
    @Published private(set) var trafficSignState = TrafficSignState()
    @Published private(set) var trafficSignStatus = "SIGN AI PAUSED • PERFORMANCE MODE"

    var horizontalFieldOfViewDegrees: Double = 0
    var effectiveFocalPixelsAt1920: Double?
    private var totalFrames: UInt64 = 0
    private var lastPublishedAt = ProcessInfo.processInfo.systemUptime
    private var inferenceFrameCounter = 0
    private var laneFrameCounter = 1
    private var lastVehicleSeenAt: TimeInterval = 0
    private var lastLaneSeenAt: TimeInterval = 0
    private let detector: VehicleDetector?
    private let distanceEstimator = DistanceEstimator()
    private let leadDistanceTracker = LeadDistanceTracker()
    private let laneDetector: LaneAIDetector?
    private let laneDepartureMonitor = LaneDepartureMonitor()
    private var latestLaneDetection: LaneDetection?

    init() {
        do { detector = try VehicleDetector(); detectorStatus = "VEHICLE MODEL READY" } catch { detector = nil; detectorStatus = error.localizedDescription }
        do { laneDetector = try LaneAIDetector(); laneStatus = "UFLD V2 LANE MODEL READY" } catch { laneDetector = nil; laneStatus = error.localizedDescription }
    }

    private var thermalStride: (vehicle: Int, lane: Int) {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return (2, 3)
        case .fair: return (3, 4)
        case .serious: return (4, 6)
        case .critical: return (6, 8)
        @unknown default: return (3, 4)
        }
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let sampleTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        process(pixelBuffer: pixelBuffer, timestamp: sampleTime.isFinite ? sampleTime : ProcessInfo.processInfo.systemUptime)
    }

    func process(pixelBuffer: CVPixelBuffer, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        totalFrames &+= 1; inferenceFrameCounter &+= 1; laneFrameCounter &+= 1
        let stride = thermalStride
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        var newDetections: [VehicleDetection]?, newInferenceMS: Double?, newLeadState: LeadDistanceState?
        var newLaneDetection: LaneDetection?, laneWasEvaluated = false, newLaneState: LaneDepartureState?

        if inferenceFrameCounter >= stride.vehicle, let detector {
            inferenceFrameCounter = 0
            do { let result = try detector.detect(pixelBuffer: pixelBuffer); newDetections = result.detections.map { $0.markingLead(false) }; newInferenceMS = result.inferenceMS }
            catch { let message = error.localizedDescription; DispatchQueue.main.async { [weak self] in self?.detectorStatus = "MODEL ERROR: \(message)" } }
        }

        if laneFrameCounter >= stride.lane, let laneDetector {
            laneFrameCounter = 0; laneWasEvaluated = true
            do {
                let lane = try laneDetector.detect(pixelBuffer: pixelBuffer)
                if let lane { lastLaneSeenAt = ProcessInfo.processInfo.systemUptime; latestLaneDetection = lane; newLaneDetection = lane; newLaneState = laneDepartureMonitor.update(with: lane) }
                else if ProcessInfo.processInfo.systemUptime - lastLaneSeenAt > 0.7 { latestLaneDetection = nil; newLaneDetection = nil; newLaneState = laneDepartureMonitor.update(with: nil) }
                else { laneWasEvaluated = false }
            } catch { newLaneDetection = nil; newLaneState = laneDepartureMonitor.update(with: nil) }
        }

        if var measured = newDetections {
            if let lane = latestLaneDetection, let leadIndex = leadVehicleIndex(in: measured, lane: lane) {
                let leadBox = measured[leadIndex].boundingBox
                let rawDistance = distanceEstimator.estimate(for: leadBox, frameWidth: width, frameHeight: height, horizontalFieldOfViewDegrees: horizontalFieldOfViewDegrees, effectiveFocalPixelsAt1920: effectiveFocalPixelsAt1920)
                let tracked = leadDistanceTracker.update(rawDistance: rawDistance, leadBox: leadBox, timestamp: timestamp)
                measured[leadIndex] = measured[leadIndex].markingLead(true).withDistance(tracked.distanceMeters); newLeadState = tracked; lastVehicleSeenAt = ProcessInfo.processInfo.systemUptime
            } else if ProcessInfo.processInfo.systemUptime - lastVehicleSeenAt > 0.55 {
                leadDistanceTracker.reset(); newLeadState = LeadDistanceState(distanceMeters: nil, closingSpeedMetersPerSecond: nil, risk: .unavailable)
            }
            measured = measured.filter { $0.isLead }; newDetections = measured
        }

        let now = ProcessInfo.processInfo.systemUptime
        let shouldPublishMetrics = now - lastPublishedAt >= 0.5
        guard shouldPublishMetrics || newDetections != nil || laneWasEvaluated else { return }
        if shouldPublishMetrics { lastPublishedAt = now }
        let count = totalFrames
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if shouldPublishMetrics {
                self.frameWidth = width; self.frameHeight = height; self.processedFrames = count
                self.pipelineStatus = ProcessInfo.processInfo.thermalState == .nominal ? "IVY AI • ECO ACTIVE" : "IVY AI • THERMAL ECO"
            }
            if let newDetections {
                self.detections = newDetections
                if let newLeadState { self.leadDistanceState = newLeadState; self.leadDistanceMeters = newLeadState.distanceMeters }
                self.detectorStatus = newDetections.isEmpty ? "LEAD SEARCH • IVY CORRIDOR" : "LEAD LOCK • IVY CORRIDOR"
            }
            if let newInferenceMS { self.inferenceMS = newInferenceMS }
            if laneWasEvaluated {
                self.laneDetection = newLaneDetection; if let newLaneState { self.laneDepartureState = newLaneState }
                self.laneStatus = newLaneDetection == nil ? "LANE SEARCHING" : "LANE ACTIVE • EGO LOCK"
            }
        }
    }

    private func leadVehicleIndex(in detections: [VehicleDetection], lane: LaneDetection) -> Int? {
        let candidates = detections.indices.filter { index in
            let box = detections[index].boundingBox; let contactY = 1.0 - Double(box.minY); let contactX = Double(box.midX)
            guard let leftX = fittedLaneX(lane.leftPoints, at: contactY), let rightX = fittedLaneX(lane.rightPoints, at: contactY), rightX > leftX, contactX >= leftX, contactX <= rightX else { return false }
            guard contactY >= 0.34 && contactY <= 0.96 else { return false }
            let t = max(0.0, min(1.0, (contactY - 0.48) / (0.94 - 0.48))); let halfWidth = 0.075 + (0.235 - 0.075) * t
            return abs(contactX - 0.50) <= halfWidth
        }
        return candidates.max { lhs, rhs in
            let a = detections[lhs].boundingBox, b = detections[rhs].boundingBox
            return (1.0 - Double(a.minY)) + Double(a.width * a.height) < (1.0 - Double(b.minY)) + Double(b.width * b.height)
        }
    }

    private func fittedLaneX(_ points: [CGPoint], at y: Double) -> Double? {
        guard points.count >= 6 else { return nil }
        let count = Double(points.count), sumY = points.reduce(0.0) { $0 + Double($1.y) }, sumX = points.reduce(0.0) { $0 + Double($1.x) }
        let sumYY = points.reduce(0.0) { $0 + Double($1.y * $1.y) }, sumYX = points.reduce(0.0) { $0 + Double($1.y * $1.x) }
        let denominator = count * sumYY - sumY * sumY; guard abs(denominator) > 0.000_001 else { return nil }
        let slope = (count * sumYX - sumY * sumX) / denominator, intercept = (sumX - slope * sumY) / count; let x = slope * y + intercept
        return x.isFinite ? x : nil
    }
}
