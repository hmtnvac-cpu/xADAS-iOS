import SwiftUI
import UIKit
import VLCKit

struct SeventyMaiPlayerView: UIViewRepresentable {
    let urlString: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(view: view, urlString: urlString)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.attach(view: uiView, urlString: urlString)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject {
        private let player = VLCMediaPlayer()
        private var currentURL: String?

        func attach(view: UIView, urlString: String) {
            player.drawable = view

            guard currentURL != urlString,
                  let url = URL(string: urlString) else {
                return
            }

            currentURL = urlString
            let media = VLCMedia(url: url)
            media.addOption(":rtsp-tcp")
            media.addOption(":network-caching=150")
            media.addOption(":clock-jitter=0")
            media.addOption(":clock-synchro=0")
            player.media = media
            player.play()
        }

        func stop() {
            player.stop()
            player.drawable = nil
            currentURL = nil
        }
    }
}
