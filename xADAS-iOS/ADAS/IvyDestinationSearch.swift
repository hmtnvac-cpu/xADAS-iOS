import AVFoundation
import Combine
import CoreLocation
import MapKit
import Speech

struct IvyAddressSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    fileprivate let completion: MKLocalSearchCompletion
}

@MainActor
final class IvyDestinationSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [IvyAddressSuggestion] = []
    @Published var isListening = false
    @Published var speechError: String?

    private let completer = MKLocalSearchCompleter()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "vi-VN"))
    private let audioEngine = AVAudioEngine()
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, near location: CLLocation?) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { suggestions = []; completer.queryFragment = ""; return }
        if let location {
            completer.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        }
        completer.queryFragment = text
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = Array(completer.results.prefix(8)).map {
            IvyAddressSuggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }

    func resolve(_ suggestion: IvyAddressSuggestion, completion: @escaping (IvySearchResult?) -> Void) {
        let request = MKLocalSearch.Request(completion: suggestion.completion)
        request.resultTypes = [.address, .pointOfInterest]
        MKLocalSearch(request: request).start { response, _ in
            guard let item = response?.mapItems.first else { completion(nil); return }
            let name = item.name ?? suggestion.title
            let subtitle = [item.placemark.subThoroughfare, item.placemark.thoroughfare, item.placemark.locality, item.placemark.administrativeArea]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            completion(IvySearchResult(name: name, subtitle: subtitle.isEmpty ? suggestion.subtitle : subtitle, coordinate: item.placemark.coordinate))
        }
    }

    func toggleVoice(onText: @escaping (String) -> Void) {
        if isListening { stopVoice(); return }
        speechError = nil
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard status == .authorized else { self?.speechError = "Chưa cấp quyền nhận dạng giọng nói"; return }
                self?.requestMicrophoneAndStart(onText: onText)
            }
        }
    }

    private func requestMicrophoneAndStart(onText: @escaping (String) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else { self?.speechError = "Chưa cấp quyền micro"; return }
                self?.startVoice(onText: onText)
            }
        }
    }

    private func startVoice(onText: @escaping (String) -> Void) {
        stopVoice()
        guard let recognizer, recognizer.isAvailable else { speechError = "Nhận dạng giọng nói chưa sẵn sàng"; return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.mixWithOthers])
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            speechRequest = request
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let text = result?.bestTranscription.formattedString, !text.isEmpty { onText(text) }
                    if result?.isFinal == true || error != nil { self?.stopVoice() }
                }
            }
        } catch {
            speechError = "Không thể bật micro"
            stopVoice()
        }
    }

    func stopVoice() {
        if audioEngine.isRunning { audioEngine.stop(); audioEngine.inputNode.removeTap(onBus: 0) }
        speechRequest?.endAudio(); speechTask?.cancel(); speechRequest = nil; speechTask = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
