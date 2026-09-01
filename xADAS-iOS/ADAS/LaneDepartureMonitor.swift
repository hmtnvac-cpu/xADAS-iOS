import Foundation

final class LaneDepartureMonitor {
    private var leftCount = 0
    private var rightCount = 0
    private var centeredCount = 0

    private let triggerFrames = 4
    private let clearFrames = 3
    private let warningOffset = 0.58
    private let clearOffset = 0.42

    private(set) var state: LaneDepartureState = .unavailable

    func update(with detection: LaneDetection?) -> LaneDepartureState {
        guard let detection, detection.confidence >= 0.32 else {
            leftCount = 0
            rightCount = 0
            centeredCount = 0
            state = .unavailable
            return state
        }

        let offset = detection.normalizedCenterOffset

        if offset <= -warningOffset {
            leftCount += 1
            rightCount = 0
            centeredCount = 0
            if leftCount >= triggerFrames {
                state = .warningLeft
            }
        } else if offset >= warningOffset {
            rightCount += 1
            leftCount = 0
            centeredCount = 0
            if rightCount >= triggerFrames {
                state = .warningRight
            }
        } else if abs(offset) <= clearOffset {
            centeredCount += 1
            leftCount = 0
            rightCount = 0
            if centeredCount >= clearFrames {
                state = .centered
            }
        } else {
            leftCount = max(leftCount - 1, 0)
            rightCount = max(rightCount - 1, 0)
            centeredCount = 0
        }

        return state
    }
}
