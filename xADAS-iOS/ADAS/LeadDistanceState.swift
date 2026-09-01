import Foundation

enum LeadDistanceRisk: String, Equatable {
    case unavailable
    case safe
    case caution
    case danger

    var displayText: String {
        switch self {
        case .unavailable: return "NO LEAD DISTANCE"
        case .safe: return "SAFE DISTANCE"
        case .caution: return "DISTANCE WARNING"
        case .danger: return "DISTANCE DANGER"
        }
    }
}

struct LeadDistanceState: Equatable {
    let distanceMeters: Double?
    let closingSpeedMetersPerSecond: Double?
    let risk: LeadDistanceRisk
}
