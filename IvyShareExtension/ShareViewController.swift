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
        guard !providers.isEmpty else { finish(); return }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            load(provider, type: UTType.url.identifier); return
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            load(provider, type: UTType.plainText.identifier); return
        }
        if let provider = providers.first, let type = provider.registeredTypeIdentifiers.first {
            load(provider, type: type); return
        }
        finish()
    }

    private func load(_ provider: NSItemProvider, type: String) {
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            if let url = item as? URL { self?.openIvy(with: url.absoluteString); return }
            if let url = item as? NSURL { self?.openIvy(with: (url as URL).absoluteString); return }
            if let text = item as? String { self?.openIvy(with: text); return }
            if let data = item as? Data, let text = String(data: data, encoding: .utf8) { self?.openIvy(with: text); return }
            self?.finish()
        }
    }

    private func openIvy(with sharedValue: String?) {
        guard let sharedValue, !sharedValue.isEmpty else { finish(); return }
        let extracted = firstURL(in: sharedValue) ?? sharedValue
        var components = URLComponents()
        components.scheme = "ivy"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "url", value: extracted)]
        guard let url = components.url else { finish(); return }
        DispatchQueue.main.async { [weak self] in
            self?.extensionContext?.open(url) { _ in self?.finish() }
        }
    }

    private func firstURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.url?.absoluteString
    }

    private func finish() {
        DispatchQueue.main.async { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
    }
}
