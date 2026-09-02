import CoreGraphics
import Foundation

enum LaneDepartureState: String, Equatable {
    case unavailable
    case centered
    case warningLeft
    case warningRight

    var displayText: String? {
        switch self {
        case .unavailable, .centered:
            return nil
        case .warningLeft:
            return "LỆCH LÀN TRÁI"
        case .warningRight:
            return "LỆCH LÀN PHẢI"
        }
    }
}

struct LaneDetection: Equatable {
    /// Normalized points in top-left image coordinates.
    let leftPoints: [CGPoint]
    let rightPoints: [CGPoint]
    let confidence: Double
    /// Vehicle offset from lane center, normalized by half lane width.
    /// Negative means vehicle is left of lane center; positive means right.
    let normalizedCenterOffset: Double
}
