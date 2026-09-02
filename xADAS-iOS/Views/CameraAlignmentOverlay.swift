import SwiftUI

/// A functional two-axis calibration guide inspired by 70mai's ADAS setup.
/// The saved crossing point drives the lead-vehicle ROI and lane offset math.
struct CameraAlignmentOverlay: View {
    @Binding var isPresented: Bool
    @AppStorage(DistanceEstimator.cameraCenterXKey) private var centerX = 0.50
    @AppStorage(DistanceEstimator.horizonRatioKey) private var horizonY = 0.42
    @AppStorage(DistanceEstimator.vehicleROIWidthKey) private var roiWidth = 0.58
    @State private var scanProgress = 0.0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let crossX = CGFloat(centerX) * size.width
            let crossY = CGFloat(horizonY) * size.height
            let roiHalf = CGFloat(roiWidth) * size.width / 2

            ZStack {
                Color.black.opacity(0.10)

                Canvas { context, canvasSize in
                    let horizontal = Path { path in
                        path.move(to: CGPoint(x: 0, y: crossY))
                        path.addLine(to: CGPoint(x: canvasSize.width, y: crossY))
                    }
                    let vertical = Path { path in
                        path.move(to: CGPoint(x: crossX, y: 0))
                        path.addLine(to: CGPoint(x: crossX, y: canvasSize.height))
                    }
                    context.stroke(
                        horizontal,
                        with: .color(.cyan),
                        style: StrokeStyle(lineWidth: 2, dash: [10, 7])
                    )
                    context.stroke(
                        vertical,
                        with: .color(.cyan),
                        style: StrokeStyle(lineWidth: 2, dash: [10, 7])
                    )

                    let roi = CGRect(
                        x: max(0, crossX - roiHalf),
                        y: max(0, crossY - canvasSize.height * 0.08),
                        width: min(canvasSize.width, roiHalf * 2),
                        height: canvasSize.height * 0.72
                    )
                    context.stroke(
                        Path(roundedRect: roi, cornerRadius: 12),
                        with: .color(.green.opacity(0.85)),
                        style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                    )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            centerX = min(max(Double(value.location.x / size.width), 0.25), 0.75)
                            horizonY = min(max(Double(value.location.y / size.height), 0.20), 0.68)
                        }
                )

                Rectangle()
                    .fill(.cyan.opacity(0.35))
                    .frame(width: 1, height: size.height)
                    .position(x: CGFloat(scanProgress) * size.width, y: size.height / 2)
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(.cyan.opacity(0.28))
                    .frame(width: size.width, height: 1)
                    .position(x: size.width / 2, y: CGFloat(scanProgress) * size.height)
                    .allowsHitTesting(false)

                Circle()
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 20, height: 20)
                    .position(x: crossX, y: crossY)
                    .allowsHitTesting(false)

                VStack(spacing: 5) {
                    Text("CĂN TÂM ADAS")
                        .font(.headline.bold())
                    Text("Kéo vòng tròn vào điểm tụ giữa hai làn")
                        .font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)

                Button("LƯU") { isPresented = false }
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 11)
                    .background(.green.opacity(0.88), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 18)
            }
        }
        .onAppear {
            scanProgress = 0.08
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: true)) {
                scanProgress = 0.92
            }
        }
    }
}
