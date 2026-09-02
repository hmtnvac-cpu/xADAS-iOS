import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showRoadGuide = true
    @State private var showDebugHUD = true
    @AppStorage(LeadDistanceTracker.referenceDistanceKey) private var referenceDistance: Double = 55
    @AppStorage(DistanceEstimator.cameraHeightKey) private var cameraHeight: Double = 1.25
    @StateObject private var rtspProbe = RTSPProbe()
    @StateObject private var warningManager = ADASWarningManager()

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
                    LabeledContent("Lane / LDW", value: "UFLD V2 AI enabled")
                    LabeledContent("Distance warning", value: "Beep + voice + vibration")
                    Button("TEST WARNING SOUND + VOICE") {
                        warningManager.testWarning()
                    }
                    Text("Distance and lane warnings use the iPhone system media volume without lowering music.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Re-run CALIBRATE after switching from the iPhone camera to the fixed 70mai camera so distance and horizon match the dashcam mounting position.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Distance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Camera height: \(cameraHeight, specifier: "%.2f") m")
                        Slider(value: $cameraHeight, in: 0.60...2.00, step: 0.01)
                    }
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
                    LabeledContent("Version", value: "0.9.4")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("Video source", value: "70mai A500S RTSP only")
                    LabeledContent("RTSP", value: "Native low-latency + watchdog")
                    LabeledContent("Lane model", value: "UFLD V2 • on-device")
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
