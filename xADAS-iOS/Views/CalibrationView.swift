import SwiftUI

struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DistanceEstimator.cameraHeightKey) private var cameraHeight: Double = 1.25
    @AppStorage(DistanceEstimator.horizonRatioKey) private var horizonRatio: Double = 0.42

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera geometry") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Camera height: \(cameraHeight, specifier: "%.2f") m")
                        Slider(value: $cameraHeight, in: 0.60...2.00, step: 0.01)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Horizon: \(Int(horizonRatio * 100))% from top")
                        Slider(value: $horizonRatio, in: 0.25...0.65, step: 0.005)
                    }
                }

                Section("How to calibrate") {
                    Text("Mount the phone in its normal driving position. Set Camera height to the rear-camera lens height above the road. Adjust Horizon until the dashed horizon line matches the real road horizon on a flat road.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Distance model") {
                    Text("V0.4 estimates lead distance from the bottom of the detected vehicle, the calibrated road horizon, camera height and the rear camera field of view. Values are smoothed to reduce frame-to-frame jumping.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Calibrate")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
