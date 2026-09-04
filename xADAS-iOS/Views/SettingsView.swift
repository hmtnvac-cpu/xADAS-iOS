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
    @AppStorage(DistanceEstimator.seventyMaiFocalPixelsKey) private var seventyMaiFocalPixels: Double = 890
    @AppStorage(VehicleSpeedMonitor.speedScaleKey) private var gpsSpeedScale: Double = 1.0
    @AppStorage(VehicleSpeedMonitor.speedOffsetKey) private var gpsSpeedOffset: Double = 0.0
    @StateObject private var rtspProbe = RTSPProbe()
    @StateObject private var warningManager = ADASWarningManager()

    private let seventyMaiURL = CameraSource.seventyMaiURL
    private var warningPercent: Binding<Double> {
        Binding(get: { max(1, min(100, (warningVolume * 100).rounded())) },
                set: { warningVolume = max(1, min(100, $0)) / 100.0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    Picker("Camera source", selection: $cameraSourceRaw) {
                        ForEach(CameraSourceChoice.allCases) { source in Text(source.title).tag(source.rawValue) }
                    }.pickerStyle(.segmented)
                    if cameraSourceRaw == CameraSourceChoice.seventyMai.rawValue {
                        LabeledContent("RTSP URL", value: "192.168.0.1/00000000")
                        Button("TEST 70MAI RTSP") { rtspProbe.probe(urlString: seventyMaiURL) }
                        HStack { Circle().fill(rtspProbe.isReachable ? Color.green : Color.orange).frame(width: 9, height: 9); Text(rtspProbe.status).font(.footnote.monospaced()) }
                    }
                }
                Section("GPS Speed") {
                    VStack(alignment: .leading, spacing: 8) { Text("Speed scale: \(gpsSpeedScale, specifier: "%.3f")×"); Slider(value: $gpsSpeedScale, in: 0.85...1.20, step: 0.005) }
                    VStack(alignment: .leading, spacing: 8) { Text("Speed offset: \(gpsSpeedOffset >= 0 ? "+" : "")\(gpsSpeedOffset, specifier: "%.1f") km/h"); Slider(value: $gpsSpeedOffset, in: -15...15, step: 0.5) }
                    Button("RESET GPS SPEED CALIBRATION") { gpsSpeedScale = 1.0; gpsSpeedOffset = 0.0 }
                }
                Section("ADAS") {
                    LabeledContent("Vehicle / lead", value: "Priority")
                    LabeledContent("Lead distance", value: "Lane-gated")
                    LabeledContent("Lane / LDW", value: "UFLD V2 AI")
                    LabeledContent("Traffic signs", value: "Paused • performance mode")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Warning volume"); Spacer(); Text("\(Int(warningPercent.wrappedValue)) / 100").monospacedDigit().bold() }
                        Slider(value: warningPercent, in: 1...100, step: 1)
                    }
                    Toggle("Warning vibration", isOn: $warningVibration)
                    Button("TEST WARNING SOUND + VOICE") { warningManager.testWarning() }
                    Text("Distance audio is enabled only above 60 km/h. Lane departure remains independent.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Distance") {
                    VStack(alignment: .leading, spacing: 8) { Text("Camera height: \(cameraHeight, specifier: "%.2f") m"); Slider(value: $cameraHeight, in: 0.60...2.00, step: 0.01) }
                    if cameraSourceRaw == CameraSourceChoice.seventyMai.rawValue {
                        VStack(alignment: .leading, spacing: 8) { Text("70mai focal: \(Int(seventyMaiFocalPixels)) px @1920"); Slider(value: $seventyMaiFocalPixels, in: 500...1300, step: 10) }
                    }
                    VStack(alignment: .leading, spacing: 8) { Text("Reference distance: \(Int(referenceDistance)) m"); Slider(value: $referenceDistance, in: 20...120, step: 5) }
                    Text("Re-run CALIBRATE after changing camera source or camera position.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Overlay") { Toggle("Road guide", isOn: $showRoadGuide); Toggle("Debug HUD", isOn: $showDebugHUD) }
                Section("Build") {
                    LabeledContent("App", value: "Ivy")
                    LabeledContent("Minimum iOS", value: "16.0")
                    LabeledContent("Video source", value: "70mai / iPhone selectable")
                    LabeledContent("Lane model", value: "UFLD V2 • on-device")
                    LabeledContent("Distance", value: "Ground-plane + calibrated focal")
                }
            }
            .navigationTitle("Ivy Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.onDisappear { rtspProbe.stop() }
    }
}
