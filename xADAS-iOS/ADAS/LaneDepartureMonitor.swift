import Foundation

/// Lane departure logic for the selected ego lane.
/// Uses smoothed lateral offset plus movement trend so a single noisy lane frame
/// does not trigger a warning, while a vehicle moving quickly toward a boundary can
/// warn before the camera center actually reaches the line.
final class LaneDepartureMonitor {
    private var leftCount = 0
    private var rightCount = 0
    private var centeredCount = 0
    private var filteredOffset: Double = 0
    private var hasFilteredOffset = false
    private var previousOffset: Double = 0
    private var previousTime: TimeInterval = 0

    private let triggerFrames = 2
    private let predictiveFrames = 3
    private let clearFrames = 3
    private let hardWarningOffset = 0.56
    private let predictiveOffset = 0.40
    private let clearOffset = 0.25
    private let minimumOutwardRate = 0.18

    private(set) var state: LaneDepartureState = .unavailable

    func update(with detection: LaneDetection?) -> LaneDepartureState {
        guard let detection, detection.confidence >= 0.34 else {
            leftCount = 0
            rightCount = 0
            centeredCount = 0
            hasFilteredOffset = false
            previousTime = 0
            state = .unavailable
            return state
        }

        let rawOffset = detection.normalizedCenterOffset
        if hasFilteredOffset {
            filteredOffset = filteredOffset * 0.62 + rawOffset * 0.38
        } else {
            filteredOffset = rawOffset
            previousOffset = rawOffset
            hasFilteredOffset = true
        }

        let now = ProcessInfo.processInfo.systemUptime
        var rate = 0.0
        if previousTime > 0 {
            let dt = max(0.03, min(now - previousTime, 0.5))
            rate = (filteredOffset - previousOffset) / dt
        }
        previousOffset = filteredOffset
        previousTime = now

        let leftHard = filteredOffset <= -hardWarningOffset
        let rightHard = filteredOffset >= hardWarningOffset
        let leftPredictive = filteredOffset <= -predictiveOffset && rate <= -minimumOutwardRate
        let rightPredictive = filteredOffset >= predictiveOffset && rate >= minimumOutwardRate

        if leftHard || leftPredictive {
            leftCount += 1
            rightCount = 0
            centeredCount = 0
            let needed = leftHard ? triggerFrames : predictiveFrames
            if leftCount >= needed { state = .warningLeft }
        } else if rightHard || rightPredictive {
            rightCount += 1
            leftCount = 0
            centeredCount = 0
            let needed = rightHard ? triggerFrames : predictiveFrames
            if rightCount >= needed { state = .warningRight }
        } else if abs(filteredOffset) <= clearOffset {
            centeredCount += 1
            leftCount = 0
            rightCount = 0
            if centeredCount >= clearFrames { state = .centered }
        } else {
            // In the buffer zone keep some history but decay it. This prevents an
            // instant clear/retrigger cycle on curves or dashed lane markings.
            leftCount = max(leftCount - 1, 0)
            rightCount = max(rightCount - 1, 0)
            centeredCount = 0
        }

        return state
    }
}
