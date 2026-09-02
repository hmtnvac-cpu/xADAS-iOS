import Foundation
import SwiftUI

struct ADASOverlayView: View {
    let isCameraRunning: Bool
    let fps: Double
    let pipelineStatus: String
    let detectorStatus: String
    let inferenceMS: Double
    let frameWidth: Int
    let frameHeight: Int
    let detections: [VehicleDetection]
    let leadDistanceState: LeadDistanceState
    let horizonRatio: Double
    let laneDetection: LaneDetection?
    let laneStatus: String
    let laneDepartureState: LaneDepartureState

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("xADAS")
                                .font(.headline.bold())
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isCameraRunning ? .green : .yellow)
                                    .frame(width: 7, height: 7)
                                Text(cameraLabel)
                                    .font(.caption2.monospaced().bold())
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    Spacer()
                }

                ForEach(detections) { detection in
                    detectionBox(detection, in: proxy.size)
                }

                if let laneDetection {
                    laneOverlay(laneDetection, in: proxy.size)
                }

                if let distance = leadDistanceState.distanceMeters {
                    Text(String(format: "%.1f m", distance))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(distanceColor.opacity(0.86), in: RoundedRectangle(cornerRadius: 12))
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.43)
                } else if isCameraRunning {
                    Text("-- m")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 10))
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.43)
                }

                if let warning = laneDepartureState.displayText {
                    Text("⚠︎ \(warning)")
                        .font(.headline.monospaced().bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.20)
                }
            }
            .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
    }

    private var cameraLabel: String {
        if isCameraRunning { return "70MAI" }
        if pipelineStatus.contains("NO RTP") { return "NO RTP" }
        if pipelineStatus.contains("RTP RECEIVING") { return "DECODING" }
        if pipelineStatus.contains("WAITING RTP") { return "WAITING RTP" }
        if pipelineStatus.contains("SETUP") { return "RTSP READY" }
        if pipelineStatus.contains("FAILED") || pipelineStatus.contains("ERROR") {
            return "CAMERA ERROR"
        }
        return "CONNECTING"
    }

    private var distanceColor: Color {
        switch leadDistanceState.risk {
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        case .unavailable: return .gray
        }
    }

    @ViewBuilder
    private func detectionBox(_ detection: VehicleDetection, in size: CGSize) -> some View {
        let rect = displayRect(for: detection.boundingBox, in: size)
        let color: Color = detection.isLead ? distanceColor : .green

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .stroke(color, lineWidth: detection.isLead ? 4 : 2)

            if detection.isLead, let distance = detection.distanceMeters {
                Text(String(format: "%.1f m", distance))
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(color)
                    .offset(y: -22)
            }
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .position(x: rect.midX, y: rect.midY)
    }

    private func labelText(for detection: VehicleDetection) -> String {
        let confidence = Int(detection.confidence * 100)
        if detection.isLead {
            if let distance = detection.distanceMeters {
                return String(format: "LEAD • %.1f m • %@ %d%%", distance, detection.label.uppercased(), confidence)
            }
            return "LEAD • \(detection.label.uppercased()) \(confidence)%"
        }
        return "\(detection.label.uppercased()) \(confidence)%"
    }

    private func displayRect(for normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: normalized.minX * size.width,
            y: (1 - normalized.maxY) * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func laneOverlay(_ lane: LaneDetection, in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            var left = Path()
            var right = Path()

            for (index, point) in lane.leftPoints.enumerated() {
                let p = CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)
                if index == 0 { left.move(to: p) } else { left.addLine(to: p) }
            }

            for (index, point) in lane.rightPoints.enumerated() {
                let p = CGPoint(x: point.x * canvasSize.width, y: point.y * canvasSize.height)
                if index == 0 { right.move(to: p) } else { right.addLine(to: p) }
            }

            let leftWarning = laneDepartureState == .warningLeft
            let rightWarning = laneDepartureState == .warningRight
            let leftColor: Color = leftWarning ? .red : .cyan
            let rightColor: Color = rightWarning ? .red : .cyan

            context.stroke(left, with: .color(leftColor.opacity(0.30)), lineWidth: leftWarning ? 13 : 9)
            context.stroke(right, with: .color(rightColor.opacity(0.30)), lineWidth: rightWarning ? 13 : 9)
            context.stroke(left, with: .color(leftColor), lineWidth: leftWarning ? 7 : 4)
            context.stroke(right, with: .color(rightColor), lineWidth: rightWarning ? 7 : 4)
        }
    }

    private func roadGuide(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let centerX = canvasSize.width / 2
            let savedHorizon = min(max(horizonRatio, 0.20), 0.75)
            let clampedHorizon = min(max(savedHorizon + 0.12, 0.46), 0.68)
            let horizonY = canvasSize.height * clampedHorizon
            let bottomY = canvasSize.height * 0.92

            var left = Path()
            left.move(to: CGPoint(x: centerX - canvasSize.width * 0.05, y: horizonY))
            left.addLine(to: CGPoint(x: centerX - canvasSize.width * 0.25, y: bottomY))

            var right = Path()
            right.move(to: CGPoint(x: centerX + canvasSize.width * 0.05, y: horizonY))
            right.addLine(to: CGPoint(x: centerX + canvasSize.width * 0.25, y: bottomY))

            context.stroke(left, with: .color(.green.opacity(0.82)), lineWidth: 3)
            context.stroke(right, with: .color(.green.opacity(0.82)), lineWidth: 3)

            let horizon = Path { path in
                path.move(to: CGPoint(x: centerX - 45, y: horizonY))
                path.addLine(to: CGPoint(x: centerX + 45, y: horizonY))
            }
            context.stroke(horizon, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }
}
