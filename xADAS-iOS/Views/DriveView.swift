import SwiftUI

struct DriveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CameraSource.selectionKey) private var cameraSourceRaw = CameraSourceChoice.seventyMai.rawValue
    @AppStorage(ADASWarningManager.audioModeKey) private var audioModeRaw = ADASAudioMode.allWarnings.rawValue
    @State private var showCalibration = false
    @State private var showSettings = false
    @State private var showNavigationSearch = false
    @State private var rtspStatus = "70MAI STARTING"
    @State private var restartToken = UUID()
    @State private var useVLCFallback = false
    @State private var configuredSourceRaw: String?
    @State private var didInitialConfigure = false
    @State private var visionSuspended = false
    @StateObject private var frameProcessor = FrameProcessor()
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var warningManager = ADASWarningManager()
    @StateObject private var vehicleSpeedMonitor = VehicleSpeedMonitor()
    @StateObject private var mapSpeedLimitProvider = MapSpeedLimitProvider()
    @StateObject private var navigationProvider = MapNavigationProvider()

    private let seventyMaiURL = CameraSource.seventyMaiURL
    private var selectedSource: CameraSourceChoice { CameraSourceChoice(rawValue: cameraSourceRaw) ?? .seventyMai }
    private var activeProcessor: FrameProcessor { selectedSource == .iPhone ? cameraManager.frameProcessor : frameProcessor }
    private var audioMode: ADASAudioMode { ADASAudioMode(rawValue: audioModeRaw) ?? .allWarnings }

    var body: some View {
        ZStack {
            Group {
                if visionSuspended {
                    Color.black
                } else if selectedSource == .iPhone {
                    CameraPreview(session: cameraManager.session)
                } else if useVLCFallback {
                    SeventyMaiPlayerView(urlString: seventyMaiURL, restartToken: restartToken, frameProcessor: frameProcessor, statusText: $rtspStatus)
                } else {
                    RootlessSeventyMaiPlayerView(urlString: seventyMaiURL, restartToken: restartToken, frameProcessor: frameProcessor, statusText: $rtspStatus)
                }
            }.ignoresSafeArea()

            if !visionSuspended {
                ADASOverlayView(
                    isCameraRunning: activeProcessor.frameWidth > 0 && activeProcessor.frameHeight > 0,
                    cameraName: selectedSource == .iPhone ? "iPhone" : "70mai",
                    fps: selectedSource == .iPhone ? cameraManager.fps : (frameProcessor.frameWidth > 0 ? 4.5 : 0),
                    pipelineStatus: selectedSource == .iPhone ? "IPHONE CAMERA ACTIVE" : rtspStatus,
                    detectorStatus: activeProcessor.detectorStatus, inferenceMS: activeProcessor.inferenceMS,
                    frameWidth: activeProcessor.frameWidth, frameHeight: activeProcessor.frameHeight,
                    detections: activeProcessor.detections, leadDistanceState: activeProcessor.leadDistanceState,
                    horizonRatio: UserDefaults.standard.double(forKey: DistanceEstimator.horizonRatioKey),
                    laneDetection: activeProcessor.laneDetection, laneStatus: activeProcessor.laneStatus,
                    laneDepartureState: activeProcessor.laneDepartureState, trafficSignState: activeProcessor.trafficSignState,
                    trafficSignStatus: activeProcessor.trafficSignStatus,
                    mapSpeedLimitKPH: mapSpeedLimitProvider.speedLimitKPH,
                    cameraSpeedLimitKPH: nil,
                    mapStatus: mapSpeedLimitProvider.status,
                    vehicleSpeedKPH: vehicleSpeedMonitor.speedKPH,
                    navigationSummary: navigationProvider.summary
                )
            }

            if showCalibration { CameraAlignmentOverlay(isPresented: $showCalibration) }

            VStack {
                HStack(spacing: 10) {
                    Spacer()
                    navigationButton
                    speakerMenu
                }
                .padding(.top, 58)
                .padding(.trailing, 18)
                Spacer()
                if !visionSuspended, selectedSource == .seventyMai, (frameProcessor.frameWidth == 0 || frameProcessor.frameHeight == 0) {
                    Button("RETRY 70MAI") {
                        rtspStatus = "70MAI RETRYING"
                        useVLCFallback = false
                        restartToken = UUID()
                        scheduleNativeFallbackCheck(for: restartToken)
                    }
                    .buttonStyle(ADASButtonStyle())
                    .padding(.bottom, 70)
                }
            }
            .foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            if !showCalibration && !visionSuspended {
                HStack(spacing: 16) {
                    Button("CALIBRATE") { showCalibration = true }
                    Button("SETTING") { showSettings = true }
                }
                .buttonStyle(ADASButtonStyle())
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNavigationSearch) { NavigationSearchView(provider: navigationProvider) }
        .onAppear {
            visionSuspended = false
            vehicleSpeedMonitor.start()
            if !didInitialConfigure {
                didInitialConfigure = true
                configureSelectedSource(force: true)
            }
            updateWarnings(distance: activeProcessor.leadDistanceState, lane: activeProcessor.laneDepartureState)
        }
        .onChange(of: cameraSourceRaw) { _ in configureSelectedSource(force: true) }
        .onChange(of: vehicleSpeedMonitor.latestLocation) { location in
            guard !visionSuspended, let location else { return }
            mapSpeedLimitProvider.ingest(location: location)
            navigationProvider.ingest(location: location)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                visionSuspended = false
                vehicleSpeedMonitor.start()
                if configuredSourceRaw != cameraSourceRaw {
                    configureSelectedSource(force: true)
                } else if selectedSource == .iPhone && !cameraManager.isRunning {
                    cameraManager.start()
                } else if selectedSource == .seventyMai {
                    rtspStatus = "70MAI RESUMING"
                    restartToken = UUID()
                    scheduleNativeFallbackCheck(for: restartToken)
                }
            case .background:
                visionSuspended = true
                vehicleSpeedMonitor.stop()
                cameraManager.stop()
                useVLCFallback = false
                rtspStatus = "IVY SUSPENDED"
                restartToken = UUID()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: activeProcessor.leadDistanceState) { value in
            guard !visionSuspended else { return }
            updateWarnings(distance: value, lane: activeProcessor.laneDepartureState)
        }
        .onChange(of: activeProcessor.laneDepartureState) { value in
            guard !visionSuspended else { return }
            updateWarnings(distance: activeProcessor.leadDistanceState, lane: value)
        }
        .onChange(of: vehicleSpeedMonitor.speedKPH) { _ in
            guard !visionSuspended else { return }
            updateWarnings(distance: activeProcessor.leadDistanceState, lane: activeProcessor.laneDepartureState)
        }
        .persistentSystemOverlays(.hidden)
    }

    private var navigationButton: some View {
        Menu {
            if navigationProvider.isNavigating {
                Button("Điểm đến mới", systemImage: "magnifyingglass") {
                    showNavigationSearch = true
                }
                Button("Dừng dẫn đường", systemImage: "xmark.circle") {
                    navigationProvider.stopNavigation()
                }
            } else {
                Button("Chọn điểm đến", systemImage: "location.magnifyingglass") {
                    showNavigationSearch = true
                }
            }
        } label: {
            Image(systemName: navigationProvider.isNavigating ? "location.fill" : "location")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(.black.opacity(0.58), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
        }
    }

    private var speakerMenu: some View {
        Menu {
            Button { audioModeRaw = ADASAudioMode.beepOnly.rawValue } label: {
                audioMode == .beepOnly ? Label("Chỉ tiếng bip", systemImage: "checkmark") : Label("Chỉ tiếng bip", systemImage: "speaker.wave.1")
            }
            Button { audioModeRaw = ADASAudioMode.allWarnings.rawValue } label: {
                audioMode == .allWarnings ? Label("Tất cả cảnh báo", systemImage: "checkmark") : Label("Tất cả cảnh báo", systemImage: "speaker.wave.3")
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
        warningManager.update(
            distance: distance,
            lane: lane,
            trafficSign: TrafficSignState(),
            vehicleSpeedKPH: vehicleSpeedMonitor.speedKPH
        )
    }

    private func configureSelectedSource(force: Bool = false) {
        guard force || configuredSourceRaw != cameraSourceRaw else { return }
        configuredSourceRaw = cameraSourceRaw
        switch selectedSource {
        case .seventyMai:
            cameraManager.stop()
            frameProcessor.horizontalFieldOfViewDegrees = 140
            frameProcessor.effectiveFocalPixelsAt1920 = max(UserDefaults.standard.double(forKey: DistanceEstimator.seventyMaiFocalPixelsKey), 100)
            useVLCFallback = false
            restartToken = UUID()
            rtspStatus = "70MAI STARTING"
            scheduleNativeFallbackCheck(for: restartToken)
        case .iPhone:
            frameProcessor.effectiveFocalPixelsAt1920 = nil
            useVLCFallback = false
            rtspStatus = "IPHONE CAMERA ACTIVE"
            cameraManager.start()
        }
    }

    private func scheduleNativeFallbackCheck(for token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard !visionSuspended,
                  selectedSource == .seventyMai,
                  restartToken == token,
                  !useVLCFallback,
                  frameProcessor.frameWidth == 0 || frameProcessor.frameHeight == 0 else { return }
            rtspStatus = "70MAI VLC FALLBACK"
            useVLCFallback = true
        }
    }
}

private struct ADASButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(.black.opacity(configuration.isPressed ? 0.75 : 0.5))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.5), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
