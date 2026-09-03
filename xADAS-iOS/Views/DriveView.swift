import SwiftUI

struct DriveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(CameraSource.selectionKey) private var cameraSourceRaw = CameraSourceChoice.seventyMai.rawValue
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

    private var selectedSource: CameraSourceChoice {
        CameraSourceChoice(rawValue: cameraSourceRaw) ?? .seventyMai
    }

    private var activeProcessor: FrameProcessor {
        selectedSource == .iPhone ? cameraManager.frameProcessor : frameProcessor
    }

    var body: some View {
        ZStack {
            Group {
                if selectedSource == .iPhone {
                    CameraPreview(session: cameraManager.session)
                } else if useVLCFallback {
                    SeventyMaiPlayerView(
                        urlString: seventyMaiURL,
                        restartToken: restartToken,
                        frameProcessor: frameProcessor,
                        statusText: $rtspStatus
                    )
                } else {
                    RootlessSeventyMaiPlayerView(
                        urlString: seventyMaiURL,
                        restartToken: restartToken,
                        frameProcessor: frameProcessor,
                        statusText: $rtspStatus
                    )
                }
            }
            .ignoresSafeArea()

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
                trafficSignStatus: activeProcessor.trafficSignStatus
            )

            if showCalibration {
                CameraAlignmentOverlay(isPresented: $showCalibration)
            }

            VStack {
                Spacer()

                if selectedSource == .seventyMai,
                   (frameProcessor.frameWidth == 0 || frameProcessor.frameHeight == 0) {
                    Button("RETRY 70MAI") {
                        rtspStatus = "70MAI RETRYING"
                        useVLCFallback = false
                        restartToken = UUID()
                    }
                    .buttonStyle(ADASButtonStyle())
                    .padding(.bottom, 70)
                }
            }
            .foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            if !showCalibration {
                HStack(spacing: 16) {
                    Button("CALIBRATE") { showCalibration = true }
                    Button("SETTING") { showSettings = true }
                }
                .buttonStyle(ADASButtonStyle())
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            vehicleSpeedMonitor.start()
            configureSelectedSource()
        }
        .onChange(of: cameraSourceRaw) { _ in configureSelectedSource() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                vehicleSpeedMonitor.start()
                configureSelectedSource()
            } else {
                vehicleSpeedMonitor.stop()
                if selectedSource == .iPhone { cameraManager.stop() }
            }
        }
        .onChange(of: activeProcessor.leadDistanceState) { newValue in
            updateWarnings(distance: newValue, lane: activeProcessor.laneDepartureState)
        }
        .onChange(of: activeProcessor.laneDepartureState) { newValue in
            updateWarnings(distance: activeProcessor.leadDistanceState, lane: newValue)
        }
        .onChange(of: vehicleSpeedMonitor.speedKPH) { _ in
            updateWarnings(
                distance: activeProcessor.leadDistanceState,
                lane: activeProcessor.laneDepartureState
            )
        }
        .persistentSystemOverlays(.hidden)
    }

    private func updateWarnings(distance: LeadDistanceState, lane: LaneDepartureState) {
        warningManager.update(
            distance: distance,
            lane: lane,
            vehicleSpeedKPH: vehicleSpeedMonitor.speedKPH
        )
    }

    private func configureSelectedSource() {
        switch selectedSource {
        case .seventyMai:
            cameraManager.stop()
            frameProcessor.horizontalFieldOfViewDegrees = 140
            useVLCFallback = false
            restartToken = UUID()
            rtspStatus = "70MAI STARTING"
            scheduleNativeFallbackCheck(for: restartToken)
        case .iPhone:
            useVLCFallback = false
            rtspStatus = "IPHONE CAMERA ACTIVE"
            cameraManager.start()
        }
    }

    private func scheduleNativeFallbackCheck(for token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard selectedSource == .seventyMai,
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
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
