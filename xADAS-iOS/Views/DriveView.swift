import SwiftUI

struct DriveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CameraSource.selectionKey) private var cameraSourceRaw = CameraSourceChoice.seventyMai.rawValue
    @AppStorage(ADASWarningManager.audioModeKey) private var audioModeRaw = ADASAudioMode.allWarnings.rawValue
    @State private var showCalibration = false
    @State private var showSettings = false
    @State private var rtspStatus = "70MAI STARTING"
    @State private var restartToken = UUID()
    @State private var useVLCFallback = false
    @StateObject private var frameProcessor = FrameProcessor()
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var warningManager = ADASWarningManager()
    @StateObject private var vehicleSpeedMonitor = VehicleSpeedMonitor()

    private let seventyMaiURL = CameraSource.seventyMaiURL
    private var selectedSource: CameraSourceChoice { CameraSourceChoice(rawValue: cameraSourceRaw) ?? .seventyMai }
    private var activeProcessor: FrameProcessor { selectedSource == .iPhone ? cameraManager.frameProcessor : frameProcessor }
    private var audioMode: ADASAudioMode { ADASAudioMode(rawValue: audioModeRaw) ?? .allWarnings }

    var body: some View {
        ZStack {
            Group {
                if selectedSource == .iPhone {
                    CameraPreview(session: cameraManager.session)
                } else if useVLCFallback {
                    SeventyMaiPlayerView(urlString: seventyMaiURL, restartToken: restartToken, frameProcessor: frameProcessor, statusText: $rtspStatus)
                } else {
                    RootlessSeventyMaiPlayerView(urlString: seventyMaiURL, restartToken: restartToken, frameProcessor: frameProcessor, statusText: $rtspStatus)
                }
            }.ignoresSafeArea()

            ADASOverlayView(
                isCameraRunning: activeProcessor.frameWidth > 0 && activeProcessor.frameHeight > 0,
                cameraName: selectedSource == .iPhone ? "iPhone" : "70mai",
                fps: selectedSource == .iPhone ? cameraManager.fps : (frameProcessor.frameWidth > 0 ? 4.5 : 0),
                pipelineStatus: selectedSource == .iPhone ? "IPHONE CAMERA ACTIVE" : rtspStatus,
                detectorStatus: activeProcessor.detectorStatus,
                inferenceMS: activeProcessor.inferenceMS,
                frameWidth: activeProcessor.frameWidth,
                frameHeight: activeProcessor.frameHeight,
                detections: activeProcessor.detections,
                leadDistanceState: activeProcessor.leadDistanceState,
                horizonRatio: UserDefaults.standard.double(forKey: DistanceEstimator.horizonRatioKey),
                laneDetection: activeProcessor.laneDetection,
                laneStatus: activeProcessor.laneStatus,
                laneDepartureState: activeProcessor.laneDepartureState,
                trafficSignState: activeProcessor.trafficSignState,
                trafficSignStatus: activeProcessor.trafficSignStatus,
                mapSpeedLimitKPH: nil,
                cameraSpeedLimitKPH: nil,
                mapStatus: "SIGN/MAP PAUSED",
                vehicleSpeedKPH: vehicleSpeedMonitor.speedKPH
            )

            if showCalibration { CameraAlignmentOverlay(isPresented: $showCalibration) }

            VStack {
                HStack {
                    Spacer()
                    speakerMenu
                        .padding(.top, 58)
                        .padding(.trailing, 18)
                }
                Spacer()
                if selectedSource == .seventyMai, (frameProcessor.frameWidth == 0 || frameProcessor.frameHeight == 0) {
                    Button("RETRY 70MAI") {
                        rtspStatus = "70MAI RETRYING"; useVLCFallback = false; restartToken = UUID()
                    }.buttonStyle(ADASButtonStyle()).padding(.bottom, 70)
                }
            }.foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            if !showCalibration {
                HStack(spacing: 16) {
                    Button("CALIBRATE") { showCalibration = true }
                    Button("SETTING") { showSettings = true }
                }.buttonStyle(ADASButtonStyle()).padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            vehicleSpeedMonitor.start(); configureSelectedSource()
            updateWarnings(distance: activeProcessor.leadDistanceState, lane: activeProcessor.laneDepartureState)
        }
        .onChange(of: cameraSourceRaw) { _ in configureSelectedSource() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { vehicleSpeedMonitor.start(); configureSelectedSource() }
            else { vehicleSpeedMonitor.stop(); if selectedSource == .iPhone { cameraManager.stop() } }
        }
        .onChange(of: activeProcessor.leadDistanceState) { value in updateWarnings(distance: value, lane: activeProcessor.laneDepartureState) }
        .onChange(of: activeProcessor.laneDepartureState) { value in updateWarnings(distance: activeProcessor.leadDistanceState, lane: value) }
        .onChange(of: vehicleSpeedMonitor.speedKPH) { _ in updateWarnings(distance: activeProcessor.leadDistanceState, lane: activeProcessor.laneDepartureState) }
        .persistentSystemOverlays(.hidden)
    }

    private var speakerMenu: some View {
        Menu {
            Button {
                audioModeRaw = ADASAudioMode.beepOnly.rawValue
            } label: {
                if audioMode == .beepOnly {
                    Label("Chỉ tiếng bip", systemImage: "checkmark")
                } else {
                    Text("Chỉ tiếng bip")
                }
            }

            Button {
                audioModeRaw = ADASAudioMode.allWarnings.rawValue
            } label: {
                if audioMode == .allWarnings {
                    Label("Tất cả cảnh báo", systemImage: "checkmark")
                } else {
                    Text("Tất cả cảnh báo")
                }
            }
        } label: {
            Image(systemName: audioMode == .beepOnly ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.58), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
        }
    }

    private func updateWarnings(distance: LeadDistanceState, lane: LaneDepartureState) {
        warningManager.update(distance: distance, lane: lane, trafficSign: TrafficSignState(), vehicleSpeedKPH: vehicleSpeedMonitor.speedKPH)
    }

    private func configureSelectedSource() {
        switch selectedSource {
        case .seventyMai:
            cameraManager.stop()
            frameProcessor.horizontalFieldOfViewDegrees = 140
            frameProcessor.effectiveFocalPixelsAt1920 = max(UserDefaults.standard.double(forKey: DistanceEstimator.seventyMaiFocalPixelsKey), 100)
            useVLCFallback = false; restartToken = UUID(); rtspStatus = "70MAI STARTING"
            scheduleNativeFallbackCheck(for: restartToken)
        case .iPhone:
            frameProcessor.effectiveFocalPixelsAt1920 = nil
            useVLCFallback = false; rtspStatus = "IPHONE CAMERA ACTIVE"; cameraManager.start()
        }
    }

    private func scheduleNativeFallbackCheck(for token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard selectedSource == .seventyMai, restartToken == token, !useVLCFallback,
                  frameProcessor.frameWidth == 0 || frameProcessor.frameHeight == 0 else { return }
            rtspStatus = "70MAI VLC FALLBACK"; useVLCFallback = true
        }
    }
}

private struct ADASButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.bold()).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(.black.opacity(configuration.isPressed ? 0.75 : 0.5))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
