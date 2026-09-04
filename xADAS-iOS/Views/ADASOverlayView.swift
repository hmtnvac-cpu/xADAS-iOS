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
    let vehicleSpeedKPH: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                Text("Ivy")
                                    .font(.system(size: 24, weight: .black, design: .rounded))
                                    .italic()
                                Text("♥")
                                    .font(.system(size: 20, weight: .black, design: .rounded))
                                    .foregroundStyle(.pink)
                            }
                            HStack(spacing: 5) {
                                Circle().fill(isCameraRunning ? .green : .yellow).frame(width: 7, height: 7)
                                Text(cameraLabel).font(.caption2.monospaced().bold())
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            HStack(spacing: 5) {
                                Circle().fill(laneIndicatorColor).frame(width: 7, height: 7)
                                Text(laneIndicatorText).font(.caption2.monospaced().bold())
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 12)
                    Spacer()
                }

                // White = detected physical ego-lane boundaries.
                if let laneDetection { laneOverlay(laneDetection, in: proxy.size) }
                // Blue = fixed forward vehicle/distance corridor. It is deliberately
                // separate from Lane AI and stays visually stable on screen.
                distanceCorridor(in: proxy.size)

                ForEach(detections) { detection in detectionBox(detection, in: proxy.size) }

                gpsSpeedometer.position(x: 64, y: proxy.size.height - 72)
                compactDistanceHUD.position(x: proxy.size.width - 62, y: proxy.size.height - 68)

                if let warning = laneDepartureState.displayText {
                    Text("⚠︎ \(warning)")
                        .font(.headline.monospaced().bold()).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.red.opacity(0.90), in: RoundedRectangle(cornerRadius: 10))
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.20)
                }
            }
            .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
    }

    private var gpsSpeedometer: some View {
        ZStack {
            Circle().fill(.black.opacity(0.58))
            Circle().stroke(.white.opacity(0.75), lineWidth: 1.5)
            VStack(spacing: -1) {
                Text(String(Int(vehicleSpeedKPH.rounded())))
                    .font(.system(size: 27, weight: .black, design: .rounded)).monospacedDigit()
                Text("km/h").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.82))
            }
        }.frame(width: 72, height: 72)
    }

    private var compactDistanceHUD: some View {
        HStack(spacing: 5) {
            Text("DIST").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.72))
            Text(leadDistanceState.distanceMeters.map { String(format: "%.1fm", $0) } ?? "--m")
                .font(.system(size: 16, weight: .black, design: .rounded))
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
        if laneStatus.contains("ERROR") || laneStatus.contains("missing") || laneStatus.contains("Missing") { return "LANE AI • ERROR" }
        if laneStatus.contains("SEARCHING") { return "LANE AI • SEARCH" }
        return "LANE AI • READY"
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
        case .unavailable: return .white
        }
    }

    @ViewBuilder private func detectionBox(_ detection: VehicleDetection, in size: CGSize) -> some View {
        let rect = displayRect(for: detection.boundingBox, in: size)
        if detection.isLead {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).stroke(distanceColor.opacity(0.88), lineWidth: 1.5)
                if let distance = detection.distanceMeters {
                    Text(String(format: "%.1f m", distance)).font(.caption2.monospaced().bold()).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 3).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).offset(y: -22)
                }
            }
            .frame(width: max(rect.width, 1), height: max(rect.height, 1)).position(x: rect.midX, y: rect.midY)
        }
    }

    private func displayRect(for normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }

    private func laneOverlay(_ lane: LaneDetection, in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let left = smoothPath(stabilizedLanePoints(lane.leftPoints), in: canvasSize)
            let right = smoothPath(stabilizedLanePoints(lane.rightPoints), in: canvasSize)
            // Physical lane markings are always thin white guides. Warning state is
            // communicated separately, so the road image remains clean.
            context.stroke(left, with: .color(.white.opacity(0.92)), lineWidth: 1.35)
            context.stroke(right, with: .color(.white.opacity(0.92)), lineWidth: 1.35)
        }
    }

    private func distanceCorridor(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let bottomY = canvasSize.height * 0.94
            let topY = canvasSize.height * 0.48
            let bottomHalf = canvasSize.width * 0.235
            let topHalf = canvasSize.width * 0.075
            let centerX = canvasSize.width * 0.50
            var left = Path(); left.move(to: CGPoint(x: centerX - bottomHalf, y: bottomY)); left.addLine(to: CGPoint(x: centerX - topHalf, y: topY))
            var right = Path(); right.move(to: CGPoint(x: centerX + bottomHalf, y: bottomY)); right.addLine(to: CGPoint(x: centerX + topHalf, y: topY))
            context.stroke(left, with: .color(.blue.opacity(0.88)), lineWidth: 1.25)
            context.stroke(right, with: .color(.blue.opacity(0.88)), lineWidth: 1.25)
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
            let previous = mapped[index - 1], current = mapped[index]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = mapped.last { path.addLine(to: last) }
        return path
    }
}
