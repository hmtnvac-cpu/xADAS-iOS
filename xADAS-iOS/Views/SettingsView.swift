import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showRoadGuide = true
    @State private var showDebugHUD = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Overlay") {
                    Toggle("Road guide", isOn: $showRoadGuide)
                    Toggle("Debug HUD", isOn: $showDebugHUD)
                }

                Section("Build") {
                    LabeledContent("Version", value: "0.4")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("Vehicle detector", value: "Apple YOLOv3Tiny Int8")
                    LabeledContent("Inference", value: "Core ML + Vision")
                    LabeledContent("Distance", value: "Pinhole + ground plane")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
