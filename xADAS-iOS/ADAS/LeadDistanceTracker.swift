import CoreGraphics
import Foundation

final class LeadDistanceTracker {
    static let referenceDistanceKey = "xadas.distance.referenceMeters"

    private var recentDistances: [Double] = []
    private var previousBox: CGRect?
    private var previousFilteredDistance: Double?
    private var previousTimestamp: TimeInterval?

    init() {
        UserDefaults.standard.register(defaults: [
            Self.referenceDistanceKey: 55.0
        ])
    }

    func update(
        rawDistance: Double?,
        leadBox: CGRect?,
        timestamp: TimeInterval
    ) -> LeadDistanceState {
        guard let rawDistance, let leadBox else {
            reset()
            return LeadDistanceState(
                distanceMeters: nil,
                closingSpeedMetersPerSecond: nil,
                risk: .unavailable
            )
        }

        if let previousBox, intersectionOverUnion(previousBox, leadBox) < 0.12 {
            recentDistances.removeAll(keepingCapacity: true)
            previousFilteredDistance = nil
            previousTimestamp = nil
        }
        previousBox = leadBox

        if let median = median(recentDistances),
           recentDistances.count >= 3 {
            let allowedJump = max(5.0, median * 0.35)
            if abs(rawDistance - median) > allowedJump {
                return state(
                    distance: previousFilteredDistance ?? median,
                    closingSpeed: nil
                )
            }
        }

        recentDistances.append(rawDistance)
        if recentDistances.count > 7 {
            recentDistances.removeFirst(recentDistances.count - 7)
        }

        let medianDistance = median(recentDistances) ?? rawDistance
        let filtered: Double
        if let previousFilteredDistance {
            filtered = previousFilteredDistance + 0.30 * (medianDistance - previousFilteredDistance)
        } else {
            filtered = medianDistance
        }

        var closingSpeed: Double?
        if let previousFilteredDistance,
           let previousTimestamp {
            let dt = timestamp - previousTimestamp
            if dt >= 0.08 && dt <= 1.5 {
                let rate = (previousFilteredDistance - filtered) / dt
                if rate.isFinite && abs(rate) <= 60 {
                    closingSpeed = rate
                }
            }
        }

        self.previousFilteredDistance = filtered
        self.previousTimestamp = timestamp

        return state(distance: filtered, closingSpeed: closingSpeed)
    }

    func reset() {
        recentDistances.removeAll(keepingCapacity: true)
        previousBox = nil
        previousFilteredDistance = nil
        previousTimestamp = nil
    }

    private func state(distance: Double, closingSpeed: Double?) -> LeadDistanceState {
        let reference = max(UserDefaults.standard.double(forKey: Self.referenceDistanceKey), 5)
        let dangerThreshold = max(12.0, reference * 0.45)

        let risk: LeadDistanceRisk
        if distance < dangerThreshold {
            risk = .danger
        } else if distance < reference {
            risk = .caution
        } else {
            risk = .safe
        }

        return LeadDistanceState(
            distanceMeters: distance,
            closingSpeedMetersPerSecond: closingSpeed,
            risk: risk
        )
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2.0
        }
        return sorted[middle]
    }

    private func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }

        let intersectionArea = Double(intersection.width * intersection.height)
        let unionArea = Double(a.width * a.height + b.width * b.height - intersection.width * intersection.height)
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}
