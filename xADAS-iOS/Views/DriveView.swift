import SwiftUI

struct DriveView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var showCalibration = false
    @State private var showSettings = false
    @State private var rtspStatus = "70MAI STARTING"
    @State private var restartToken = UUID()
    @AppStorage(CameraSource.seventyMaiURLKey) private var seventyMaiURL = "rtsp://192.168.0.1:554/00000000"

    var body: some View {
        ZStack {
            SeventyMaiPlayerView(
                urlString: seventyMaiURL,
                restartToken: restartToken,
                statusText: $rtspStatus
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.24), .clear, .black.opacity(0.34)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("xADAS")
                            .font(.title2.bold())
                        Text("70MAI A500S • RTSP")
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(rtspStatus == "70MAI PLAYING" ? .green : .yellow)
                        Text(rtspStatus)
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(rtspStatus.contains("ERROR") || rtspStatus.contains("FAILED") ? .red : .white.opacity(0.9))
                        Text("VIDEO SOURCE • DASHCAM ONLY")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("V0.8.1")
                            .font(.caption.monospaced().bold())
                        Text("RTSP /00000000")
                            .font(.caption2.monospaced())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                if rtspStatus != "70MAI PLAYING" {
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
            CameraSource.registerDefaults()
            restartToken = UUID()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                restartToken = UUID()
            }
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
