import SwiftUI
import UIKit
import VLCKit

struct SeventyMaiPlayerView: UIViewRepresentable {
    let urlString: String
    let restartToken: UUID
    @Binding var statusText: String

    func makeCoordinator() -> Coordinator {
        Coordinator(statusText: $statusText)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(
            view: view,
            urlString: urlString,
            restartToken: restartToken
        )
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.statusText = $statusText
        context.coordinator.attach(
            view: uiView,
            urlString: urlString,
            restartToken: restartToken
        )
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        fileprivate var statusText: Binding<String>
        private let player = VLCMediaPlayer()
        private var currentURL: String?
        private var currentRestartToken: UUID?
        private weak var currentView: UIView?

        init(statusText: Binding<String>) {
            self.statusText = statusText
            super.init()
            player.delegate = self
        }

        func attach(view: UIView, urlString: String, restartToken: UUID) {
            currentView = view
            player.drawable = view

            let needsRestart = currentURL != urlString || currentRestartToken != restartToken
            guard needsRestart else { return }

            currentURL = urlString
            currentRestartToken = restartToken
            start(urlString: urlString)
        }

        private func start(urlString: String) {
            player.stop()
            setStatus("70MAI CONNECTING")

            guard let url = URL(string: urlString),
                  let media = VLCMedia(url: url) else {
                setStatus("70MAI URL INVALID")
                return
            }

            media.addOption(":rtsp-tcp")
            media.addOption(":network-caching=250")
            media.addOption(":live-caching=250")
            media.addOption(":clock-jitter=0")
            media.addOption(":clock-synchro=0")

            player.media = media
            if let currentView {
                player.drawable = currentView
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                if !self.player.play() {
                    self.setStatus("70MAI PLAY FAILED")
                }
            }
        }

        func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
            switch newState {
            case .opening:
                setStatus("70MAI OPENING")
            case .playing:
                setStatus("70MAI PLAYING")
            case .paused:
                setStatus("70MAI PAUSED")
            case .stopping:
                setStatus("70MAI STOPPING")
            case .stopped:
                setStatus("70MAI STOPPED • RETRY")
            case .error:
                setStatus("70MAI ERROR • RETRY")
            case .nothingSpecial:
                setStatus("70MAI WAITING")
            @unknown default:
                setStatus("70MAI UNKNOWN STATE")
            }
        }

        func mediaPlayerBufferingChanged(_ progress: Float) {
            guard progress < 1 else { return }
            setStatus(String(format: "70MAI BUFFERING %.0f%%", progress * 100))
        }

        func stop() {
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
    }
}
