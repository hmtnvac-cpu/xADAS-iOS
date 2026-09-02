import Foundation

enum CameraSource {
    static let seventyMaiURLKey = "xadas.camera.70mai.rtspURL"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            seventyMaiURLKey: "rtsp://192.168.0.1:554/00000000"
        ])
    }
}
