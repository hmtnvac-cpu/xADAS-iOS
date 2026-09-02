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

                    Text("The RTSP source is fixed to the exact URL confirmed working in VLC. xADAS does not send record, album or configuration commands to the dashcam.")
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
                    LabeledContent("Version", value: "0.8.2")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("Video source", value: "70mai A500S RTSP only")
                    LabeledContent("RTSP transport", value: "VLC default negotiation")
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
