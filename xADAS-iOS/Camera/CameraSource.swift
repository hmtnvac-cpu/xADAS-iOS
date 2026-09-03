import Foundation

enum CameraSourceChoice: String, CaseIterable, Identifiable {
    case seventyMai
    case iPhone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .seventyMai: return "70mai A500S"
        case .iPhone: return "iPhone Camera"
        }
    }
}

enum CameraSource {
    static let seventyMaiURL = "rtsp://192.168.0.1/00000000"
    static let selectionKey = "xadas.camera.source"
}
