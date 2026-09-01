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
    let leadDistanceMeters: Double?
    let horizonRatio: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VStack {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("xADAS")
                                .font(.title2.bold())
                            Text(isCameraRunning ? "CAMERA ONLINE" : "CAMERA STARTING")
                                .font(.caption2.monospaced().bold())
                                .foregroundStyle(isCameraRunning ? .green : .yellow)
                            Text(pipelineStatus)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.8))
                            Text(detectorStatus)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.white.opacity(0.8))
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("V0.4")
                                .font(.caption.monospaced().bold())
                            Text(String(format: "FPS %.1f", fps))
                                .font(.caption2.monospaced())
                            Text(String(format: "AI %.1f ms", inferenceMS))
                                .font(.caption2.monospaced())
                            if frameWidth > 0 && frameHeight > 0 {
                                Text("\(frameWidth)×\(frameHeight)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    if let leadDistanceMeters {
                        Text(String(format: "%.1f m", leadDistanceMeters))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.top, 8)
                    }

                    Spacer()
                }

                roadGuide(in: proxy.size)

                ForEach(detections) { detection in
                    detectionBox(detection, in: proxy.size)
                }
            }
            .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func detectionBox(_ detection: VehicleDetection, in size: CGSize) -> some View {
        let rect = displayRect(for: detection.boundingBox, in: size)
        let color: Color = detection.isLead ? .yellow : .green

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .stroke(color, lineWidth: detection.isLead ? 4 : 2)

            Text(labelText(for: detection))
                .font(.caption2.monospaced().bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(color)
                .offset(y: -22)
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

    private func roadGuide(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let centerX = canvasSize.width / 2
            let clampedHorizon = min(max(horizonRatio, 0.20), 0.75)
            let horizonY = canvasSize.height * clampedHorizon
            let bottomY = canvasSize.height * 0.9

            var left = Path()
            left.move(to: CGPoint(x: centerX - canvasSize.width * 0.05, y: horizonY))
            left.addLine(to: CGPoint(x: centerX - canvasSize.width * 0.25, y: bottomY))

            var right = Path()
            right.move(to: CGPoint(x: centerX + canvasSize.width * 0.05, y: horizonY))
            right.addLine(to: CGPoint(x: centerX + canvasSize.width * 0.25, y: bottomY))

            context.stroke(left, with: .color(.green.opacity(0.8)), lineWidth: 3)
            context.stroke(right, with: .color(.green.opacity(0.8)), lineWidth: 3)

            let horizon = Path { path in
                path.move(to: CGPoint(x: centerX - 45, y: horizonY))
                path.addLine(to: CGPoint(x: centerX + 45, y: horizonY))
            }
            context.stroke(horizon, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }
}
