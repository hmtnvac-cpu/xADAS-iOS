import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("xadas.overlay.roadGuide") private var showRoadGuide = true
    @AppStorage("xadas.overlay.debugHUD") private var showDebugHUD = true
    @AppStorage(CameraSource.selectionKey) private var cameraSourceRaw = CameraSourceChoice.seventyMai.rawValue
    @AppStorage(ADASWarningManager.volumeKey) private var warningVolume: Double = 0.35
    @AppStorage(ADASWarningManager.vibrationKey) private var warningVibration = true
    @AppStorage(LeadDistanceTracker.referenceDistanceKey) private var referenceDistance: Double = 55
    @AppStorage(DistanceEstimator.cameraHeightKey) private var cameraHeight: Double = 1.25
    @StateObject private var rtspProbe = RTSPProbe()
    @StateObject private var warningManager = ADASWarningManager()

    private let seventyMaiURL = CameraSource.seventyMaiURL

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    Picker("Camera source", selection: $cameraSourceRaw) {
                        ForEach(CameraSourceChoice.allCases) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    if cameraSourceRaw == CameraSourceChoice.seventyMai.rawValue {
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
                    } else {
                        Text("iPhone rear camera is available for development and roadside testing when the 70mai hotspot is not connected.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("ADAS") {
                    LabeledContent("Vehicle / lead", value: "Enabled")
                    LabeledContent("Lead distance", value: "Lane-gated")
                    LabeledContent("Lane / LDW", value: "UFLD V2 AI")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Warning volume: \(Int(warningVolume * 100))%")
                        Slider(value: $warningVolume, in: 0...1, step: 0.05)
                    }

                    Toggle("Warning vibration", isOn: $warningVibration)

                    Button("TEST WARNING SOUND + VOICE") {
                        warningManager.testWarning()
                    }

                    Text("xADAS warning volume is independent from the app logic, while iPhone media volume remains the final system output level.")
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
                    Text("Re-run CALIBRATE after changing camera source because camera height, FOV and horizon differ between the iPhone and 70mai.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Overlay") {
                    Toggle("Road guide", isOn: $showRoadGuide)
                    Toggle("Debug HUD", isOn: $showDebugHUD)
                }

                Section("Build") {
                    LabeledContent("Version", value: "0.9.8+")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("Video source", value: "70mai / iPhone selectable")
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
