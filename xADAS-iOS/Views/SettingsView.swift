import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showRoadGuide = true
    @State private var showDebugHUD = true
    @AppStorage(LeadDistanceTracker.referenceDistanceKey) private var referenceDistance: Double = 55
    @AppStorage(CameraSource.seventyMaiURLKey) private var seventyMaiURL = "rtsp://192.168.0.1:554/00000000"
    @StateObject private var rtspProbe = RTSPProbe()

    var body: some View {
        NavigationStack {
            Form {
                Section("70mai A500S") {
                    LabeledContent("Camera source", value: "70mai only")

                    TextField("RTSP URL", text: $seventyMaiURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("TEST 70MAI RTSP") {
                        rtspProbe.probe(urlString: seventyMaiURL)
                    }

                    HStack {
                        Circle()
                            .fill(rtspProbe.isReachable ? Color.green : Color.orange)
                            .frame(width: 9, height: 9)
                        Text(rtspProbe.status)
                            .font(.footnote.monospaced())
                    }

                    Text("xADAS uses the 70mai RTSP stream as its driving camera. No 70mai record, album or configuration commands are sent.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Distance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reference distance: \(Int(referenceDistance)) m")
                        Slider(value: $referenceDistance, in: 20...120, step: 5)
                    }
                    Text("This threshold is still manual. Automatic speed-based distance rules will be added after the 70mai video pipeline is stable.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Overlay") {
                    Toggle("Road guide", isOn: $showRoadGuide)
                    Toggle("Debug HUD", isOn: $showDebugHUD)
                }

                Section("Build") {
                    LabeledContent("Version", value: "0.8")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("Video source", value: "70mai A500S RTSP")
                    LabeledContent("RTSP player", value: "VLCKit")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { CameraSource.registerDefaults() }
        .onDisappear { rtspProbe.stop() }
    }
}
