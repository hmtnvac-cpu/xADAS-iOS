import Foundation
import CoreGraphics

struct VehicleDetection: Identifiable, Equatable {
    let id: UUID
    let label: String
    let confidence: Float
    /// Vision normalized coordinates. Origin is bottom-left.
    let boundingBox: CGRect
    let isLead: Bool

    init(
        id: UUID = UUID(),
        label: String,
        confidence: Float,
        boundingBox: CGRect,
        isLead: Bool = false
    ) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.isLead = isLead
    }

    func markingLead(_ lead: Bool) -> VehicleDetection {
        VehicleDetection(
            id: id,
            label: label,
            confidence: confidence,
            boundingBox: boundingBox,
            isLead: lead
        )
    }
}
