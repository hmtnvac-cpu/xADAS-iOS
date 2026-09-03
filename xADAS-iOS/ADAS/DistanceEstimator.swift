import CoreGraphics
import Foundation

final class DistanceEstimator {
    static let cameraHeightKey = "xadas.calibration.cameraHeight"
    static let horizonRatioKey = "xadas.calibration.horizonRatio"
    static let cameraCenterXKey = "xadas.calibration.centerX"
    static let vehicleROIWidthKey = "xadas.calibration.vehicleROIWidth"
    static let seventyMaiFocalPixelsKey = "xadas.calibration.70maiFocalPixels1920"

    init() {
        UserDefaults.standard.register(defaults: [
            Self.cameraHeightKey: 1.25,
            Self.horizonRatioKey: 0.42,
            Self.cameraCenterXKey: 0.50,
            Self.vehicleROIWidthKey: 0.58,
            // 70mai advertises a wide viewing angle, but that figure is not the
            // usable horizontal pinhole FOV of the decoded stream. Using 140°
            // as horizontal FOV produced focal lengths near 350 px and made a
            // real ~9 m lead appear around ~3 m. Use an effective calibrated
            // focal length referenced to a 1920 px-wide stream instead.
            Self.seventyMaiFocalPixelsKey: 890.0
        ])
    }

    func estimate(
        for boundingBox: CGRect,
        frameWidth: Int,
        frameHeight: Int,
        horizontalFieldOfViewDegrees: Double,
        effectiveFocalPixelsAt1920: Double? = nil
    ) -> Double? {
        guard frameWidth > 0, frameHeight > 0 else { return nil }

        let defaults = UserDefaults.standard
        let cameraHeight = defaults.double(forKey: Self.cameraHeightKey)
        let horizonRatio = defaults.double(forKey: Self.horizonRatioKey)

        guard cameraHeight > 0.2,
              horizonRatio > 0.1,
              horizonRatio < 0.9 else {
            return nil
        }

        // Vision boxes use bottom-left coordinates. Convert the vehicle/road
        // contact point to image coordinates measured from the top.
        let contactY = (1.0 - Double(boundingBox.minY)) * Double(frameHeight)
        let horizonY = horizonRatio * Double(frameHeight)
        let deltaY = contactY - horizonY
        guard deltaY > 1 else { return nil }

        let focalPixels: Double
        if let calibrated = effectiveFocalPixelsAt1920, calibrated > 100 {
            focalPixels = calibrated * Double(frameWidth) / 1920.0
        } else {
            guard horizontalFieldOfViewDegrees > 1,
                  horizontalFieldOfViewDegrees < 179 else { return nil }
            let horizontalFOV = horizontalFieldOfViewDegrees * .pi / 180.0
            // Square-pixel pinhole camera: fx in pixels is also the focal pixel
            // scale used for vertical ray angles. This avoids deriving vfov
            // through an incorrect advertised/diagonal camera angle.
            focalPixels = (Double(frameWidth) / 2.0) / tan(horizontalFOV / 2.0)
        }

        guard focalPixels.isFinite, focalPixels > 50 else { return nil }

        // Ground-plane ray intersection. The angle below the model horizon is
        // atan(deltaY / f); range is h / tan(angle). Writing it explicitly
        // keeps the geometry valid beyond the small-angle approximation and
        // makes horizon/pitch calibration meaningful.
        let rayAngleBelowHorizon = atan2(deltaY, focalPixels)
        let tangent = tan(rayAngleBelowHorizon)
        guard tangent > 0.0001 else { return nil }

        let distance = cameraHeight / tangent
        guard distance.isFinite,
              distance >= 0.5,
              distance <= 180 else {
            return nil
        }
        return distance
    }
}
