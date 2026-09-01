import SwiftUI

struct ADASOverlayView: View {
    let isCameraRunning: Bool

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
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("V0.1")
                                .font(.caption.monospaced().bold())
                            Text("FPS --")
                                .font(.caption2.monospaced())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    Spacer()
                }

                roadGuide(in: proxy.size)
            }
            .foregroundStyle(.white)
        }
        .allowsHitTesting(false)
    }

    private func roadGuide(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let centerX = canvasSize.width / 2
            let horizonY = canvasSize.height * 0.42
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
