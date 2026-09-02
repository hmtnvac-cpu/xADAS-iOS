import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showRoadGuide = true
    @State private var showDebugHUD = true
    @AppStorage(LeadDistanceTracker.referenceDistanceKey) private var referenceDistance: Double = 55
    @StateObject private var rtspProbe = RTSPProbe()

    private let seventyMaiURL = CameraSource.seventyMaiURL

    var body: some View {
        NavigationStack {
            Form {
                Section("70mai A500S") {
                    LabeledContent("Camera source", value: "70mai only")
                    LabeledContent("RTSP URL", value: "192.168.0.1/00000000")

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

                    Text("The RTSP source is fixed to the URL confirmed working on the A500S. xADAS does not send record, album or configuration commands to the dashcam.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("ADAS") {
                    LabeledContent("Vehicle / lead", value: "Enabled")
                    LabeledContent("Lead distance", value: "Enabled")
                    LabeledContent("Lane / LDW", value: "Enabled")
                    LabeledContent("Audio + vibration", value: "Enabled")
                    Text("Re-run CALIBRATE after switching from the iPhone camera to the fixed 70mai camera so distance and horizon match the dashcam mounting position.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Distance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reference distance: \(Int(referenceDistance)) m")
                        Slider(value: $referenceDistance, in: 20...120, step: 5)
                    }
                    Text("The prototype uses this manual reference threshold for caution/danger classification.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Overlay") {
                    Toggle("Road guide", isOn: $showRoadGuide)
                    Toggle("Debug HUD", isOn: $showDebugHUD)
                }

                Section("Build") {
                    LabeledContent("Version", value: "0.9.0")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("Video source", value: "70mai A500S RTSP only")
                    LabeledContent("RTSP", value: "Auto reconnect + 700 ms cache")
                    LabeledContent("AI bridge", value: "Decoded VLC snapshots")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear { rtspProbe.stop() }
    }
}
