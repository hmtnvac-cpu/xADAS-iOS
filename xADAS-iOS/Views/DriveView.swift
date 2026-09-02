import SwiftUI

struct DriveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCalibration = false
    @State private var showSettings = false
    @State private var rtspStatus = "70MAI STARTING"
    @State private var restartToken = UUID()
    @State private var useVLCFallback = false
    @StateObject private var frameProcessor = FrameProcessor()
    @StateObject private var warningManager = ADASWarningManager()

    private let seventyMaiURL = CameraSource.seventyMaiURL

    var body: some View {
        ZStack {
            Group {
                if useVLCFallback {
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
                isCameraRunning: frameProcessor.frameWidth > 0 && frameProcessor.frameHeight > 0,
                fps: frameProcessor.frameWidth > 0 ? 4.5 : 0,
                pipelineStatus: rtspStatus,
                detectorStatus: frameProcessor.detectorStatus,
                inferenceMS: frameProcessor.inferenceMS,
                frameWidth: frameProcessor.frameWidth,
                frameHeight: frameProcessor.frameHeight,
                detections: frameProcessor.detections,
                leadDistanceState: frameProcessor.leadDistanceState,
                horizonRatio: UserDefaults.standard.double(forKey: DistanceEstimator.horizonRatioKey),
                laneDetection: frameProcessor.laneDetection,
                laneStatus: frameProcessor.laneStatus,
                laneDepartureState: frameProcessor.laneDepartureState
            )

            if showCalibration {
                CameraAlignmentOverlay(isPresented: $showCalibration)
            }

            VStack {
                Spacer()

                if frameProcessor.frameWidth == 0 || frameProcessor.frameHeight == 0 {
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
            frameProcessor.horizontalFieldOfViewDegrees = 140
            scheduleNativeFallbackCheck(for: restartToken)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                useVLCFallback = false
                restartToken = UUID()
                scheduleNativeFallbackCheck(for: restartToken)
            }
        }
        .onChange(of: frameProcessor.leadDistanceState) { newValue in
            warningManager.update(distance: newValue, lane: frameProcessor.laneDepartureState)
        }
        .onChange(of: frameProcessor.laneDepartureState) { newValue in
            warningManager.update(distance: frameProcessor.leadDistanceState, lane: newValue)
        }
        .persistentSystemOverlays(.hidden)
    }

    private func scheduleNativeFallbackCheck(for token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            guard restartToken == token, !useVLCFallback,
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
