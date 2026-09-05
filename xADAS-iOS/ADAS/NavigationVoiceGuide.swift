import AVFoundation
import Foundation

final class NavigationVoiceGuide: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var announcedKey = ""
    private var ownsPlaybackSession = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func update(_ summary: IvyNavigationSummary?) {
        guard UserDefaults.standard.string(forKey: ADASWarningManager.audioModeKey) != ADASAudioMode.beepOnly.rawValue,
              let summary else { announcedKey = ""; return }
        let distance = summary.maneuverDistanceMeters
        guard distance > 0, distance <= 220 else { return }
        let action: String
        switch summary.modifier {
        case "left": action = "Rẽ trái"
        case "right": action = "Rẽ phải"
        case "uturn": action = "Quay đầu"
        case "roundabout": action = "Vào vòng xuyến"
        default: return
        }
        let bucket: String
        let phrase: String
        if distance > 80 { bucket = "200"; phrase = "Còn 200 mét, \(action.lowercased())" }
        else { bucket = "now"; phrase = action }
        let key = "\(summary.instruction)|\(bucket)"
        guard key != announcedKey else { return }
        announcedKey = key

        if !ownsPlaybackSession { IvyAudioSessionManager.shared.beginPlayback(); ownsPlaybackSession = true }
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
        utterance.rate = 0.52
        utterance.volume = Float(min(max(UserDefaults.standard.double(forKey: ADASWarningManager.volumeKey), 0.05), 1))
        synthesizer.speak(utterance)
    }

    private func finishPlayback() {
        guard ownsPlaybackSession, !synthesizer.isSpeaking else { return }
        ownsPlaybackSession = false
        IvyAudioSessionManager.shared.endPlayback()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finishPlayback() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finishPlayback() }
}
