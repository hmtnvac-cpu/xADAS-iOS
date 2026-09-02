import Foundation

enum CameraSource: String, CaseIterable, Identifiable {
    case iPhone = "iphone"
    case seventyMai = "70mai"

    static let storageKey = "xadas.camera.source"
    static let seventyMaiURLKey = "xadas.camera.70mai.rtspURL"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iPhone: return "iPhone Camera"
        case .seventyMai: return "70mai A500S (RTSP)"
        }
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            storageKey: CameraSource.iPhone.rawValue,
            seventyMaiURLKey: "rtsp://192.168.0.1:554/00000000"
        ])
    }
}
