import CoreGraphics
import Foundation

final class DistanceEstimator {
    static let cameraHeightKey = "xadas.calibration.cameraHeight"
    static let horizonRatioKey = "xadas.calibration.horizonRatio"
    static let cameraCenterXKey = "xadas.calibration.centerX"
    static let vehicleROIWidthKey = "xadas.calibration.vehicleROIWidth"

    init() {
        UserDefaults.standard.register(defaults: [
            Self.cameraHeightKey: 1.25,
            Self.horizonRatioKey: 0.42,
            Self.cameraCenterXKey: 0.50,
            Self.vehicleROIWidthKey: 0.58
        ])
    }

    func estimate(
        for boundingBox: CGRect,
        frameWidth: Int,
        frameHeight: Int,
        horizontalFieldOfViewDegrees: Double
    ) -> Double? {
        guard frameWidth > 0,
              frameHeight > 0,
              horizontalFieldOfViewDegrees > 1 else {
            return nil
        }

        let defaults = UserDefaults.standard
        let cameraHeight = defaults.double(forKey: Self.cameraHeightKey)
        let horizonRatio = defaults.double(forKey: Self.horizonRatioKey)

        guard cameraHeight > 0.2,
              horizonRatio > 0.1,
              horizonRatio < 0.9 else {
            return nil
        }

        // Vision bounding boxes use a bottom-left origin. The contact point
        // with the road is approximated by the bottom edge of the lead box.
        let vehicleBottomRatio = 1.0 - Double(boundingBox.minY)
        let verticalDeltaRatio = vehicleBottomRatio - horizonRatio

        guard verticalDeltaRatio > 0.01 else { return nil }

        let aspect = Double(frameWidth) / Double(frameHeight)
        let horizontalFOV = horizontalFieldOfViewDegrees * .pi / 180.0
        let verticalFOV = 2.0 * atan(tan(horizontalFOV / 2.0) / aspect)
        let focalLengthY = (Double(frameHeight) / 2.0) / tan(verticalFOV / 2.0)
        let deltaPixels = verticalDeltaRatio * Double(frameHeight)

        guard deltaPixels > 1 else { return nil }

        let rawDistance = cameraHeight * focalLengthY / deltaPixels

        guard rawDistance.isFinite,
              rawDistance >= 0.5,
              rawDistance <= 150 else {
            return nil
        }

        // Keep this estimator geometric only. Temporal filtering and lead
        // continuity are handled by LeadDistanceTracker.
        return rawDistance
    }
}
