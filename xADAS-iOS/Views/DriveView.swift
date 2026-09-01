import SwiftUI
import AVFoundation
import AudioToolbox

struct DriveView: View {
    @StateObject private var camera = CameraManager()
    @State private var showCalibration = false
    @State private var showSettings = false
    @AppStorage(DistanceEstimator.horizonRatioKey) private var horizonRatio: Double = 0.42

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.28), .clear, .black.opacity(0.38)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ADASOverlayView(
                isCameraRunning: camera.isRunning,
                fps: camera.fps,
                pipelineStatus: camera.frameProcessor.pipelineStatus,
                detectorStatus: camera.frameProcessor.detectorStatus,
                inferenceMS: camera.frameProcessor.inferenceMS,
                frameWidth: camera.frameProcessor.frameWidth,
                frameHeight: camera.frameProcessor.frameHeight,
                detections: camera.frameProcessor.detections,
                leadDistanceState: camera.frameProcessor.leadDistanceState,
                horizonRatio: horizonRatio,
                laneDetection: camera.frameProcessor.laneDetection,
                laneStatus: camera.frameProcessor.laneStatus,
                laneDepartureState: camera.frameProcessor.laneDepartureState
            )

            if camera.authorizationStatus == .denied || camera.authorizationStatus == .restricted {
                permissionOverlay
            }

            if let error = camera.errorMessage,
               camera.authorizationStatus == .authorized {
                errorOverlay(error)
            }
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
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.frameProcessor.laneDepartureState) { state in
            guard state == .warningLeft || state == .warningRight else { return }
            AudioServicesPlaySystemSound(1057)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        .onChange(of: camera.frameProcessor.leadDistanceState.risk) { risk in
            guard risk == .danger else { return }
            AudioServicesPlaySystemSound(1057)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        .persistentSystemOverlays(.hidden)
    }

    private var permissionOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.system(size: 34))
            Text("Camera permission required")
                .font(.headline)
            Text("Enable Camera access in iOS Settings to use xADAS.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding()
    }

    private func errorOverlay(_ message: String) -> some View {
        Text(message)
            .font(.footnote.monospaced())
            .padding(12)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
            .padding()
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
