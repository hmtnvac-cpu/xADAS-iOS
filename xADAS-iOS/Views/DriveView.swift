import SwiftUI

struct DriveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCalibration = false
    @State private var showSettings = false
    @State private var rtspStatus = "70MAI STARTING"
    @State private var restartToken = UUID()
    @StateObject private var frameProcessor = FrameProcessor()
    @StateObject private var warningManager = ADASWarningManager()

    private let seventyMaiURL = CameraSource.seventyMaiURL

    var body: some View {
        ZStack {
            SeventyMaiPlayerView(
                urlString: seventyMaiURL,
                restartToken: restartToken,
                frameProcessor: frameProcessor,
                statusText: $rtspStatus
            )
            .ignoresSafeArea()

            ADASOverlayView(
                isCameraRunning: frameProcessor.frameWidth > 0 && frameProcessor.frameHeight > 0,
                fps: rtspStatus.contains("PLAYING") ? 4.5 : 0,
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

            VStack {
                Spacer()

                if frameProcessor.frameWidth == 0 || frameProcessor.frameHeight == 0 {
                    Button("RETRY 70MAI") {
                        rtspStatus = "70MAI RETRYING"
                        restartToken = UUID()
                    }
                    .buttonStyle(ADASButtonStyle())
                    .padding(.bottom, 70)
                }
            }
            .foregroundStyle(.white)
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 16) {
                Button("CALIBRATE") { showCalibration = true }
                Button("SETTING") { showSettings = true }
            }
            .buttonStyle(ADASButtonStyle())
            .padding(.bottom, 22)
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onAppear {
            frameProcessor.horizontalFieldOfViewDegrees = 140
            restartToken = UUID()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                restartToken = UUID()
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
