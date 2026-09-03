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
    let trafficSignState: TrafficSignState
    let trafficSignStatus: String
    let mapSpeedLimitKPH: Int?
    let cameraSpeedLimitKPH: Int?
    let mapStatus: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("xADAS")
                                .font(.headline.bold())
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(isCameraRunning ? .green : .yellow)
                                    .frame(width: 7, height: 7)
                                Text(cameraLabel)
                                    .font(.caption2.monospaced().bold())
                            }

                            HStack(spacing: 7) {
                                speedLimitBadge
                                Text(trafficSignState.areaLabel)
                                    .font(.caption2.monospaced().bold())
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(.black.opacity(0.56), in: Capsule())
                            }

                            Text(fusionLabel)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.78))
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 5) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(laneIndicatorColor)
                                    .frame(width: 7, height: 7)
                                Text(laneIndicatorText)
                                    .font(.caption2.monospaced().bold())
                            }
                            Text(signIndicatorText)
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(trafficSignStatus.contains("ERROR") ? .red : .white.opacity(0.78))
                            Text(mapStatus)
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.58))
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

                compactDistanceHUD
                    .position(x: proxy.size.width - 62, y: proxy.size.height - 68)

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

    private var fusionLabel: String {
        let map = mapSpeedLimitKPH.map(String.init) ?? "--"
        let camera = cameraSpeedLimitKPH.map(String.init) ?? "--"
        let final = trafficSignState.explicitSpeedLimitKPH.map(String.init) ?? "--"
        return "MAP \(map) • CAM \(camera) • FINAL \(final)"
    }

    private var speedLimitBadge: some View {
        ZStack {
            Circle()
                .fill(.white)
                .overlay(Circle().stroke(.red, lineWidth: 3.5))
                .frame(width: 38, height: 38)
            Text(trafficSignState.explicitSpeedLimitKPH.map(String.init) ?? "--")
                .font(.system(size: trafficSignState.explicitSpeedLimitKPH == nil ? 13 : 14, weight: .black, design: .rounded))
                .foregroundStyle(.black)
        }
    }

    private var compactDistanceHUD: some View {
        HStack(spacing: 5) {
            Text("DIST")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
            Text(leadDistanceState.distanceMeters.map { String(format: "%.1fm", $0) } ?? "--m")
                .font(.system(size: 16, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(distanceColor.opacity(leadDistanceState.distanceMeters == nil ? 0.48 : 0.86), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cameraLabel: String {
        if isCameraRunning { return cameraName.uppercased() }
        if pipelineStatus.contains("NO RTP") { return "NO RTP" }
        if pipelineStatus.contains("RTP RECEIVING") { return "DECODING" }
        if pipelineStatus.contains("WAITING RTP") { return "WAITING RTP" }
        if pipelineStatus.contains("SETUP") { return "RTSP READY" }
        if pipelineStatus.contains("FAILED") || pipelineStatus.contains("ERROR") { return "CAMERA ERROR" }
        return "CONNECTING"
    }

    private var laneIndicatorText: String {
        if laneStatus.contains("ACTIVE") { return "LANE AI • EGO LOCK" }
        if laneStatus.contains("ERROR") || laneStatus.contains("missing") || laneStatus.contains("Missing") {
            return "LANE AI • ERROR"
        }
        if laneStatus.contains("SEARCHING") { return "LANE AI • SEARCH" }
        return "LANE AI • READY"
    }

    private var signIndicatorText: String {
        if trafficSignStatus.contains("ERROR") { return "SIGN AI • ERROR" }
        if trafficSignStatus.contains("LIMIT") || trafficSignStatus.contains("R420") || trafficSignStatus.contains("R421") {
            return trafficSignStatus
        }
        return "SIGN AI • SEARCH"
    }

    private var laneIndicatorColor: Color {
        if laneStatus.contains("ACTIVE") { return .green }
        if laneStatus.contains("ERROR") || laneStatus.contains("missing") || laneStatus.contains("Missing") { return .red }
        return .yellow
    }

    private var distanceColor: Color {
        switch leadDistanceState.risk {
        case .safe: return .green
        case .caution: return .orange
        case .danger: return .red
        case .unavailable: return .black
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
            let leftColor: Color = leftWarning ? .red : .green
            let rightColor: Color = rightWarning ? .red : .green

            context.stroke(left, with: .color(leftColor.opacity(0.22)), lineWidth: leftWarning ? 8 : 5)
            context.stroke(right, with: .color(rightColor.opacity(0.22)), lineWidth: rightWarning ? 8 : 5)
            context.stroke(left, with: .color(leftColor), lineWidth: leftWarning ? 4 : 2.5)
            context.stroke(right, with: .color(rightColor), lineWidth: rightWarning ? 4 : 2.5)
        }
    }

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
