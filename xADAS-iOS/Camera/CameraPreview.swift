import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.applyLandscapeOrientation()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
        uiView.applyLandscapeOrientation()
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The preview connection can become available only after the capture session
        // has started. Re-apply the exact same orientation used by CameraManager so
        // the visible image and AI frames can never diverge on iOS 16.
        applyLandscapeOrientation()
    }

    func applyLandscapeOrientation() {
        guard let connection = videoPreviewLayer.connection,
              connection.isVideoOrientationSupported else { return }

        // Ivy's supported/tested runtime is iOS 16. Keep preview and AI output in the
        // same AVCapture coordinate system instead of applying a separate preview
        // rotation transform.
        connection.videoOrientation = .landscapeRight
    }
}
