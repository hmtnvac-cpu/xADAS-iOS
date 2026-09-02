import CoreGraphics
import CoreVideo
import SwiftUI
import UIKit
import VLCKit

struct SeventyMaiPlayerView: UIViewRepresentable {
    let urlString: String
    let restartToken: UUID
    let frameProcessor: FrameProcessor
    @Binding var statusText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(statusText: $statusText, frameProcessor: frameProcessor)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(view: view, urlString: urlString, restartToken: restartToken)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.statusText = $statusText
        context.coordinator.attach(view: uiView, urlString: urlString, restartToken: restartToken)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        fileprivate var statusText: Binding<String>
        private let frameProcessor: FrameProcessor
        private let player = VLCMediaPlayer()
        private let frameQueue = DispatchQueue(label: "xadas.70mai.frame", qos: .userInitiated)
        private var currentURL: String?
        private var currentRestartToken: UUID?
        private weak var currentView: UIView?
        private var snapshotTimer: Timer?
        private var reconnectWorkItem: DispatchWorkItem?
        private var snapshotInFlight = false
        private var snapshotPath: String?
        private var snapshotCounter: UInt64 = 0
        private var stoppedByOwner = false
        private var consecutiveFailures = 0

        // Rootless jailbreak builds currently crash inside VLCKit's OpenGL ES drawable
        // (VLCOpenGLES2VideoView.makeCurrent -> assert/abort) as soon as 70mai H.264
        // frames arrive. Keep libVLC headless on /var/jb so the app remains alive while
        // we validate RTSP transport. IPA/non-rootless builds keep the existing renderer.
        private var rootlessSafeMode: Bool {
            FileManager.default.fileExists(atPath: "/var/jb")
        }

        init(statusText: Binding<String>, frameProcessor: FrameProcessor) {
            self.statusText = statusText
            self.frameProcessor = frameProcessor
            super.init()
            player.delegate = self
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(snapshotTaken(_:)),
                name: VLCMediaPlayer.snapshotTakenNotification,
                object: player
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(view: UIView, urlString: String, restartToken: UUID) {
            currentView = view
            if rootlessSafeMode {
                player.drawable = nil
            } else {
                player.drawable = view
            }

            let needsRestart = currentURL != urlString || currentRestartToken != restartToken
            guard needsRestart else { return }

            currentURL = urlString
            currentRestartToken = restartToken
            stoppedByOwner = false
            consecutiveFailures = 0
            start(urlString: urlString)
        }

        private func start(urlString: String) {
            reconnectWorkItem?.cancel()
            stopSnapshotLoop()
            player.stop()
            setStatus(rootlessSafeMode ? "70MAI CONNECTING • SAFE MODE" : "70MAI CONNECTING")

            guard let url = URL(string: urlString),
                  let media = VLCMedia(url: url) else {
                setStatus("70MAI URL INVALID")
                return
            }

            media.addOption(":network-caching=700")
            media.addOption(":live-caching=700")
            media.addOption(":clock-jitter=0")

            if rootlessSafeMode {
                // Do not instantiate VLCKit's iOS OpenGL ES video output on rootless.
                // The crash log points directly at that renderer. Decode/transport stays
                // active so we can prove the RTSP session is stable before replacing vout.
                media.addOption(":no-video-title-show")
                player.drawable = nil
            }

            player.media = media
            if !rootlessSafeMode, let currentView {
                player.drawable = currentView
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, !self.stoppedByOwner else { return }
                self.player.play()
            }
        }

        func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
            switch newState {
            case .opening:
                setStatus(rootlessSafeMode ? "70MAI OPENING • SAFE MODE" : "70MAI OPENING")
            case .playing:
                consecutiveFailures = 0
                if rootlessSafeMode {
                    setStatus("70MAI RTSP OK • SAFE MODE")
                    stopSnapshotLoop()
                } else {
                    setStatus("70MAI PLAYING • ADAS ACTIVE")
                    startSnapshotLoop()
                }
            case .paused:
                setStatus("70MAI PAUSED")
                stopSnapshotLoop()
            case .stopping:
                setStatus("70MAI STOPPING")
            case .stopped:
                stopSnapshotLoop()
                if !stoppedByOwner {
                    scheduleReconnect(reason: "70MAI RECONNECTING")
                }
            case .error:
                stopSnapshotLoop()
                if !stoppedByOwner {
                    scheduleReconnect(reason: "70MAI ERROR • AUTO RETRY")
                }
            case .nothingSpecial:
                setStatus("70MAI WAITING")
            @unknown default:
                setStatus("70MAI UNKNOWN STATE")
            }
        }

        func mediaPlayerBufferingChanged(_ progress: Float) {
            if progress >= 1 {
                if player.state == .playing {
                    setStatus(rootlessSafeMode ? "70MAI RTSP OK • SAFE MODE" : "70MAI PLAYING • ADAS ACTIVE")
                }
            } else {
                setStatus(String(format: "70MAI BUFFERING %.0f%%", progress * 100))
            }
        }

        private func scheduleReconnect(reason: String) {
            consecutiveFailures += 1
            let delay = min(5.0, 0.8 + Double(consecutiveFailures - 1) * 0.8)
            setStatus("\(reason) • \(String(format: "%.1fs", delay))")
            reconnectWorkItem?.cancel()

            let item = DispatchWorkItem { [weak self] in
                guard let self,
                      !self.stoppedByOwner,
                      let url = self.currentURL else { return }
                self.start(urlString: url)
            }
            reconnectWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        private func startSnapshotLoop() {
            guard !rootlessSafeMode else { return }
            guard snapshotTimer == nil else { return }
            snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: true) { [weak self] _ in
                self?.requestSnapshot()
            }
            requestSnapshot()
        }

        private func stopSnapshotLoop() {
            snapshotTimer?.invalidate()
            snapshotTimer = nil
            snapshotInFlight = false
            if let snapshotPath {
                try? FileManager.default.removeItem(atPath: snapshotPath)
            }
            snapshotPath = nil
        }

        private func requestSnapshot() {
            guard !rootlessSafeMode else { return }
            guard player.state == .playing, !snapshotInFlight else { return }
            snapshotCounter &+= 1
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("xadas-70mai-\(snapshotCounter % 2).png")
                .path
            try? FileManager.default.removeItem(atPath: path)
            snapshotPath = path
            snapshotInFlight = true
            player.saveVideoSnapshot(at: path, withWidth: 640, andHeight: 360)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.snapshotInFlight else { return }
                self.snapshotInFlight = false
            }
        }

        @objc private func snapshotTaken(_ notification: Notification) {
            guard !rootlessSafeMode else {
                snapshotInFlight = false
                return
            }
            guard let path = snapshotPath else {
                snapshotInFlight = false
                return
            }
            snapshotInFlight = false
            frameQueue.async { [weak self] in
                guard let self,
                      let image = UIImage(contentsOfFile: path),
                      let cgImage = image.cgImage,
                      let pixelBuffer = Self.makePixelBuffer(from: cgImage) else {
                    try? FileManager.default.removeItem(atPath: path)
                    return
                }
                try? FileManager.default.removeItem(atPath: path)
                self.frameProcessor.process(pixelBuffer: pixelBuffer)
            }
        }

        func stop() {
            stoppedByOwner = true
            reconnectWorkItem?.cancel()
            stopSnapshotLoop()
            player.stop()
            player.drawable = nil
            currentURL = nil
            currentRestartToken = nil
        }

        private func setStatus(_ text: String) {
            DispatchQueue.main.async { [weak self] in
                self?.statusText.wrappedValue = text
            }
        }

        private static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
            let width = image.width
            let height = image.height
            let attributes: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                  ) else { return nil }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return pixelBuffer
        }
    }
}
