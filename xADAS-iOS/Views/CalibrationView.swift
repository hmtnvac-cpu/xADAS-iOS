import SwiftUI

struct CalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cameraHeight: Double = 1.25
    @State private var pitch: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera geometry") {
                    VStack(alignment: .leading) {
                        Text("Camera height: \(cameraHeight, specifier: "%.2f") m")
                        Slider(value: $cameraHeight, in: 0.5...2.0, step: 0.01)
                    }

                    VStack(alignment: .leading) {
                        Text("Pitch: \(pitch, specifier: "%.1f")°")
                        Slider(value: $pitch, in: -15...15, step: 0.1)
                    }
                }

                Section {
                    Text("V0.1 stores calibration only in this screen. Persistent calibration and horizon alignment will be added with distance estimation.")
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
