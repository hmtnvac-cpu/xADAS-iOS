import Foundation
import SwiftUI

struct ADASOverlayView: View {
    let isCameraRunning: Bool
    let cameraName: String
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

                        HStack(spacing: 5) {
                            Circle()
                                .fill(laneIndicatorColor)
                                .frame(width: 7, height: 7)
                            Text(laneIndicatorText)
                                .font(.caption2.monospaced().bold())
                        }
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
        if isCameraRunning { return cameraName.uppercased() }
        if pipelineStatus.contains("NO RTP") { return "NO RTP" }
        if pipelineStatus.contains("RTP RECEIVING") { return "DECODING" }
        if pipelineStatus.contains("WAITING RTP") { return "WAITING RTP" }
        if pipelineStatus.contains("SETUP") { return "RTSP READY" }
        if pipelineStatus.contains("FAILED") || pipelineStatus.contains("ERROR") {
            return "CAMERA ERROR"
        }
        return "CONNECTING"
    }

    private var laneIndicatorText: String {
        if laneStatus.contains("ACTIVE") { return "LANE AI • LOCK" }
        if laneStatus.contains("ERROR") || laneStatus.contains("missing") || laneStatus.contains("Missing") {
            return "LANE AI • ERROR"
        }
        if laneStatus.contains("SEARCHING") { return "LANE AI • SEARCH" }
        return "LANE AI • READY"
    }

    private var laneIndicatorColor: Color {
        if laneStatus.contains("ACTIVE") { return .green }
        if laneStatus.contains("ERROR") || laneStatus.contains("missing") || laneStatus.contains("Missing") {
            return .red
        }
        return .yellow
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
            let leftPoints = stabilizedLanePoints(lane.leftPoints)
            let rightPoints = stabilizedLanePoints(lane.rightPoints)
            let left = smoothPath(leftPoints, in: canvasSize)
            let right = smoothPath(rightPoints, in: canvasSize)

            let leftWarning = laneDepartureState == .warningLeft
            let rightWarning = laneDepartureState == .warningRight
            let leftColor: Color = leftWarning ? .red : .cyan
            let rightColor: Color = rightWarning ? .red : .cyan

            context.stroke(left, with: .color(leftColor.opacity(0.22)), lineWidth: leftWarning ? 8 : 5)
            context.stroke(right, with: .color(rightColor.opacity(0.22)), lineWidth: rightWarning ? 8 : 5)
            context.stroke(left, with: .color(leftColor), lineWidth: leftWarning ? 4 : 2.5)
            context.stroke(right, with: .color(rightColor), lineWidth: rightWarning ? 4 : 2.5)
        }
    }

    /// UFLD returns discrete row anchors. Drawing those raw points directly
    /// produced the saw-tooth/zig-zag lane seen on the real 70mai screen.
    /// Smooth x over nearby anchors and reject isolated large jumps.
    private func stabilizedLanePoints(_ input: [CGPoint]) -> [CGPoint] {
        let sorted = input.sorted { $0.y < $1.y }
        guard sorted.count >= 5 else { return sorted }

        var averaged: [CGPoint] = []
        for index in sorted.indices {
            let lower = max(sorted.startIndex, index - 2)
            let upper = min(sorted.index(before: sorted.endIndex), index + 2)
            let window = sorted[lower...upper]
            let x = window.reduce(0.0) { $0 + Double($1.x) } / Double(window.count)
            averaged.append(CGPoint(x: x, y: sorted[index].y))
        }

        var filtered: [CGPoint] = []
        for point in averaged {
            if let previous = filtered.last {
                let dy = max(0.01, abs(point.y - previous.y))
                let maxJump = 0.035 + dy * 0.75
                if abs(point.x - previous.x) > maxJump { continue }
            }
            filtered.append(point)
        }
        return filtered.count >= 5 ? filtered : averaged
    }

    private func smoothPath(_ points: [CGPoint], in size: CGSize) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        let mapped = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
        guard mapped.count > 1 else { return path }

        for index in 1..<mapped.count {
            let previous = mapped[index - 1]
            let current = mapped[index]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = mapped.last { path.addLine(to: last) }
        return path
    }
}
