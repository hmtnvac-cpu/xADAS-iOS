import CoreGraphics
import Foundation

/// Ivy lane-departure monitor.
///
/// The car/camera center is fixed. The physical white lane lines move relative to it.
/// We first LOCK the current ego lane while the vehicle is stably centered. During a
/// lane change we keep that original lock long enough to detect the boundary crossing;
/// we do not instantly accept the newly detected adjacent lane as the new reference.
final class LaneDepartureMonitor {
    private struct LaneGeometry {
        let leftX: Double
        let rightX: Double
        let centerX: Double
        let width: Double
    }

    private var lockedLane: LaneGeometry?
    private var candidateRelock: LaneGeometry?
    private var candidateRelockFrames = 0
    private var centeredFrames = 0
    private var leftWarningFrames = 0
    private var rightWarningFrames = 0
    private var missingFrames = 0
    private var previousCenterX: Double?
    private var filteredCenterVelocity: Double = 0
    private var previousTime: TimeInterval = 0

    private let referenceY = 0.80
    private let cameraCenterX = 0.50
    private let minimumConfidence = 0.34
    private let initialLockFrames = 4
    private let relockFrames = 10
    private let warningConfirmFrames = 2
    private let clearConfirmFrames = 4
    private let edgeMarginFraction = 0.18
    private let lockDriftFraction = 0.22
    private let predictiveDriftFraction = 0.14
    private let predictiveVelocity = 0.10

    private(set) var state: LaneDepartureState = .unavailable

    func update(with detection: LaneDetection?) -> LaneDepartureState {
        guard let detection,
              detection.confidence >= minimumConfidence,
              let geometry = geometry(from: detection),
              geometry.width > 0.12,
              geometry.width < 0.75 else {
            missingFrames += 1
            if missingFrames >= 4 {
                leftWarningFrames = 0
                rightWarningFrames = 0
                centeredFrames = 0
                previousCenterX = nil
                previousTime = 0
                state = .unavailable
            }
            return state
        }

        missingFrames = 0
        updateCenterVelocity(currentCenterX: geometry.centerX)

        if lockedLane == nil {
            if isCameraComfortablyInside(geometry) {
                centeredFrames += 1
                if centeredFrames >= initialLockFrames {
                    lockedLane = geometry
                    state = .centered
                    centeredFrames = 0
                }
            } else {
                centeredFrames = 0
                state = .unavailable
            }
            return state
        }

        guard let locked = lockedLane else { return state }

        let leftDistance = cameraCenterX - geometry.leftX
        let rightDistance = geometry.rightX - cameraCenterX
        let currentHalfWidth = geometry.width * 0.5
        let leftEdgeDanger = leftDistance <= geometry.width * edgeMarginFraction
        let rightEdgeDanger = rightDistance <= geometry.width * edgeMarginFraction
        let cameraOutsideLeft = cameraCenterX < geometry.leftX
        let cameraOutsideRight = cameraCenterX > geometry.rightX

        // Keep the original lane reference through the departure. If the currently
        // detected lane center slides far from the locked center, that is exactly the
        // event we want to warn about rather than immediately accepting the new lane.
        let centerDrift = geometry.centerX - locked.centerX
        let driftLimit = max(locked.width * lockDriftFraction, 0.045)
        let predictiveLimit = max(locked.width * predictiveDriftFraction, 0.030)

        let movingLeft = filteredCenterVelocity > predictiveVelocity
        let movingRight = filteredCenterVelocity < -predictiveVelocity

        // Image geometry: when the vehicle/camera moves left relative to the road,
        // the lane center shifts right in the image. Vice versa for a right departure.
        let leftDeparture = cameraOutsideLeft
            || leftEdgeDanger
            || centerDrift >= driftLimit
            || (centerDrift >= predictiveLimit && movingLeft)

        let rightDeparture = cameraOutsideRight
            || rightEdgeDanger
            || centerDrift <= -driftLimit
            || (centerDrift <= -predictiveLimit && movingRight)

        if leftDeparture && !rightDeparture {
            leftWarningFrames += 1
            rightWarningFrames = 0
            centeredFrames = 0
            candidateRelockFrames = 0
            if leftWarningFrames >= warningConfirmFrames {
                state = .warningLeft
            }
            return state
        }

        if rightDeparture && !leftDeparture {
            rightWarningFrames += 1
            leftWarningFrames = 0
            centeredFrames = 0
            candidateRelockFrames = 0
            if rightWarningFrames >= warningConfirmFrames {
                state = .warningRight
            }
            return state
        }

        leftWarningFrames = max(leftWarningFrames - 1, 0)
        rightWarningFrames = max(rightWarningFrames - 1, 0)

        if isCameraComfortablyInside(geometry) {
            centeredFrames += 1
        } else {
            centeredFrames = 0
        }

        // After a real lane change, accept the new lane only after it remains stable
        // for a sustained period. This prevents "instant relock" from hiding the alert.
        if state == .warningLeft || state == .warningRight {
            if isCameraComfortablyInside(geometry) {
                if let candidate = candidateRelock,
                   abs(candidate.centerX - geometry.centerX) <= max(geometry.width * 0.10, 0.025),
                   abs(candidate.width - geometry.width) <= max(geometry.width * 0.18, 0.04) {
                    candidateRelockFrames += 1
                } else {
                    candidateRelock = geometry
                    candidateRelockFrames = 1
                }

                if candidateRelockFrames >= relockFrames {
                    lockedLane = geometry
                    candidateRelock = nil
                    candidateRelockFrames = 0
                    state = .centered
                }
            } else {
                candidateRelock = nil
                candidateRelockFrames = 0
            }
        } else if centeredFrames >= clearConfirmFrames {
            // Normal road curvature: gently refresh the lock only while centered,
            // never during a suspected crossing.
            lockedLane = LaneGeometry(
                leftX: locked.leftX * 0.88 + geometry.leftX * 0.12,
                rightX: locked.rightX * 0.88 + geometry.rightX * 0.12,
                centerX: locked.centerX * 0.88 + geometry.centerX * 0.12,
                width: locked.width * 0.88 + geometry.width * 0.12
            )
            state = .centered
            centeredFrames = 0
        }

        _ = currentHalfWidth
        return state
    }

    func reset() {
        lockedLane = nil
        candidateRelock = nil
        candidateRelockFrames = 0
        centeredFrames = 0
        leftWarningFrames = 0
        rightWarningFrames = 0
        missingFrames = 0
        previousCenterX = nil
        filteredCenterVelocity = 0
        previousTime = 0
        state = .unavailable
    }

    private func geometry(from detection: LaneDetection) -> LaneGeometry? {
        guard let leftX = fittedX(detection.leftPoints, at: referenceY),
              let rightX = fittedX(detection.rightPoints, at: referenceY),
              rightX > leftX else { return nil }
        let width = rightX - leftX
        return LaneGeometry(leftX: leftX, rightX: rightX, centerX: (leftX + rightX) * 0.5, width: width)
    }

    private func isCameraComfortablyInside(_ lane: LaneGeometry) -> Bool {
        let margin = lane.width * 0.24
        return cameraCenterX >= lane.leftX + margin && cameraCenterX <= lane.rightX - margin
    }

    private func updateCenterVelocity(currentCenterX: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        if let previousCenterX, previousTime > 0 {
            let dt = max(0.03, min(now - previousTime, 0.5))
            let instantaneous = (currentCenterX - previousCenterX) / dt
            filteredCenterVelocity = filteredCenterVelocity * 0.65 + instantaneous * 0.35
        }
        previousCenterX = currentCenterX
        previousTime = now
    }

    private func fittedX(_ points: [CGPoint], at y: Double) -> Double? {
        guard points.count >= 5 else { return nil }
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
