import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showRoadGuide = true
    @State private var showDebugHUD = true
    @AppStorage(LeadDistanceTracker.referenceDistanceKey) private var referenceDistance: Double = 55
    @AppStorage(CameraSource.storageKey) private var cameraSourceRaw = CameraSource.iPhone.rawValue
    @AppStorage(CameraSource.seventyMaiURLKey) private var seventyMaiURL = "rtsp://192.168.0.1:554/00000000"
    @StateObject private var rtspProbe = RTSPProbe()

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera Source") {
                    Picker("Source", selection: $cameraSourceRaw) {
                        ForEach(CameraSource.allCases) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    }

                    if cameraSourceRaw == CameraSource.seventyMai.rawValue {
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

                        Text("Read-only test. xADAS only sends an RTSP OPTIONS request and does not send record, album, or configuration commands to the dashcam.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Distance") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reference distance: \(Int(referenceDistance)) m")
                        Slider(value: $referenceDistance, in: 20...120, step: 5)
                    }
                    Text("This is a manual reference threshold for the current prototype. It is not yet adjusted automatically from vehicle speed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Overlay") {
                    Toggle("Road guide", isOn: $showRoadGuide)
                    Toggle("Debug HUD", isOn: $showDebugHUD)
                }

                Section("Build") {
                    LabeledContent("Version", value: "0.7")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("70mai", value: "A500S RTSP probe")
                    LabeledContent("Vehicle detector", value: "Apple YOLOv3Tiny Int8")
                    LabeledContent("Distance", value: "Pinhole + lead tracking")
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
