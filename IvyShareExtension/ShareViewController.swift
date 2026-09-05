import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var didStart = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        importSharedDestination()
    }

    private func importSharedDestination() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                let url = item as? URL ?? (item as? NSURL).map { $0 as URL }
                self?.openIvy(with: url?.absoluteString)
            }
            return
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                self?.openIvy(with: item as? String)
            }
            return
        }

        finish()
    }

    private func openIvy(with sharedValue: String?) {
        guard let sharedValue, !sharedValue.isEmpty else {
            finish()
            return
        }
        var components = URLComponents()
        components.scheme = "ivy"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "url", value: sharedValue)]
        guard let url = components.url else {
            finish()
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.open(url) { _ in
                self?.finish()
            }
        }
    }

    private func finish() {
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
