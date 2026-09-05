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
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) { load(provider,type:UTType.url.identifier);return }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) { load(provider,type:UTType.plainText.identifier);return }
        if let provider=providers.first,let type=provider.registeredTypeIdentifiers.first { load(provider,type:type);return }
        finish()
    }

    private func load(_ provider:NSItemProvider,type:String){
        provider.loadItem(forTypeIdentifier:type,options:nil){[weak self] item,_ in
            if let url=item as? URL{self?.openIvy(with:url.absoluteString);return}
            if let url=item as? NSURL{self?.openIvy(with:(url as URL).absoluteString);return}
            if let text=item as? String{self?.openIvy(with:text);return}
            if let data=item as? Data,let text=String(data:data,encoding:.utf8){self?.openIvy(with:text);return}
            self?.finish()
        }
    }

    private func openIvy(with sharedValue:String?){
        guard let sharedValue,!sharedValue.isEmpty else{finish();return}
        let extracted=firstURL(in:sharedValue) ?? sharedValue
        var components=URLComponents();components.scheme="ivy";components.host="share";components.queryItems=[URLQueryItem(name:"url",value:extracted)]
        guard let url=components.url else{finish();return}
        DispatchQueue.main.async{[weak self] in
            guard let self else{return}
            self.extensionContext?.open(url){opened in
                DispatchQueue.main.async {
                    if opened { self.finish() }
                    else if self.openThroughResponderChain(url) { self.finish() }
                    else { self.showManualOpenMessage(sharedValue: extracted) }
                }
            }
        }
    }

    /// Share extensions are not guaranteed permission to launch their containing
    /// app. On iOS 16/TrollStore we also try the responder-chain URL action. If
    /// iOS rejects both paths, keep the extension visible instead of silently closing.
    private func openThroughResponderChain(_ url:URL)->Bool{
        let selector=NSSelectorFromString("openURL:")
        var responder:UIResponder?=self
        while let current=responder {
            if current.responds(to:selector) { current.perform(selector,with:url); return true }
            responder=current.next
        }
        return false
    }

    private func showManualOpenMessage(sharedValue:String){
        UIPasteboard.general.string=sharedValue
        let alert=UIAlertController(title:"Đã nhận điểm đến",message:"iOS không cho Share Extension tự mở Ivy. Điểm đến đã được sao chép; mở Ivy để tiếp tục.",preferredStyle:.alert)
        alert.addAction(UIAlertAction(title:"Đóng",style:.default){[weak self]_ in self?.finish()})
        present(alert,animated:true)
    }

    private func firstURL(in text:String)->String?{guard let detector=try? NSDataDetector(types:NSTextCheckingResult.CheckingType.link.rawValue) else{return nil};let range=NSRange(text.startIndex..<text.endIndex,in:text);return detector.firstMatch(in:text,options:[],range:range)?.url?.absoluteString}
    private func finish(){DispatchQueue.main.async{[weak self] in self?.extensionContext?.completeRequest(returningItems:nil)}}
}
