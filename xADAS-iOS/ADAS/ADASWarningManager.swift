import AVFoundation
import AudioToolbox
import Combine
import Foundation

enum ADASAudioMode: String, CaseIterable, Identifiable {
    case beepOnly, allWarnings
    var id: String { rawValue }
    var title: String { self == .beepOnly ? "Chỉ tiếng bip" : "Tất cả cảnh báo" }
}

final class ADASWarningManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let volumeKey = "xadas.warning.volume"
    static let vibrationKey = "xadas.warning.vibration"
    static let audioModeKey = "xadas.warning.audioMode"
    static let minimumDistanceAlertSpeedKPH = 60.0

    private var player: AVAudioPlayer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var lastDistanceAlertAt: TimeInterval = 0, lastLaneAlertAt: TimeInterval = 0
    private var lastOverspeedAlertAt: TimeInterval = 0, lastSpeechAt: TimeInterval = 0
    private var lastSpokenKey = ""
    private var lastDistanceRisk: LeadDistanceRisk = .unavailable
    private var lastLaneState: LaneDepartureState = .unavailable
    private var lastTrafficSignUpdatedAt: TimeInterval = 0
    private var lastTrafficSign: TrafficSignKind?

    override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Self.volumeKey: 0.35, Self.vibrationKey: true, Self.audioModeKey: ADASAudioMode.allWarnings.rawValue])
        player = try? AVAudioPlayer(data: Self.makeBeepWAV())
        player?.delegate = self; player?.prepareToPlay(); speechSynthesizer.delegate = self
        // Deliberately do not configure or activate AVAudioSession during init.
    }

    private var warningVolume: Float { Float(min(max(UserDefaults.standard.double(forKey: Self.volumeKey), 0), 1)) }
    private var vibrationEnabled: Bool { UserDefaults.standard.bool(forKey: Self.vibrationKey) }
    private var audioMode: ADASAudioMode { ADASAudioMode(rawValue: UserDefaults.standard.string(forKey: Self.audioModeKey) ?? "") ?? .allWarnings }

    func update(distance: LeadDistanceState, lane: LaneDepartureState, trafficSign: TrafficSignState, vehicleSpeedKPH: Double) {
        announceNewTrafficSignIfNeeded(trafficSign)
        let now = ProcessInfo.processInfo.systemUptime

        let laneWarning = lane == .warningLeft || lane == .warningRight
        let previousLaneWarning = lastLaneState == .warningLeft || lastLaneState == .warningRight
        if laneWarning && (!previousLaneWarning || lane != lastLaneState || now - lastLaneAlertAt >= 3.0) {
            let left = lane == .warningLeft
            alert(strong: false, message: left ? "Cảnh báo lệch làn trái" : "Cảnh báo lệch làn phải", key: left ? "lane-left" : "lane-right")
            lastLaneAlertAt = now
        }
        lastLaneState = lane

        guard vehicleSpeedKPH > Self.minimumDistanceAlertSpeedKPH else { lastDistanceRisk = .unavailable; return }

        if let limit = trafficSign.explicitSpeedLimitKPH, vehicleSpeedKPH >= Double(limit) + 5, now - lastOverspeedAlertAt >= 6 {
            alert(strong: true, message: "Cảnh báo quá tốc độ. Giới hạn \(limit) ki lô mét một giờ", key: "overspeed-\(limit)")
            lastOverspeedAlertAt = now
        }

        let danger = distance.risk == .danger && (lastDistanceRisk != .danger || now - lastDistanceAlertAt >= 2)
        let caution = distance.risk == .caution && lastDistanceRisk != .caution && now - lastDistanceAlertAt >= 1.2
        if danger { alert(strong: true, message: "Cảnh báo, khoảng cách quá gần", key: "distance-danger"); lastDistanceAlertAt = now }
        else if caution { alert(strong: false, message: "Chú ý khoảng cách", key: "distance-caution"); lastDistanceAlertAt = now }
        lastDistanceRisk = distance.risk
    }

    private func announceNewTrafficSignIfNeeded(_ state: TrafficSignState) {
        guard state.updatedAt > 0, state.updatedAt != lastTrafficSignUpdatedAt, let sign = state.lastConfirmedSign else { return }
        lastTrafficSignUpdatedAt = state.updatedAt
        guard sign != lastTrafficSign else { return }
        lastTrafficSign = sign
        switch sign {
        case .speedLimit(let value): alert(strong: false, message: "Giới hạn tốc độ \(value) ki lô mét một giờ", key: "sign-limit-\(value)", forceSpeech: true)
        case .denseAreaStart: alert(strong: false, message: "Bắt đầu khu đông dân cư", key: "sign-dense-start", forceSpeech: true)
        case .denseAreaEnd: alert(strong: false, message: "Hết khu đông dân cư", key: "sign-dense-end", forceSpeech: true)
        }
    }

    func testWarning() { alert(strong: true, message: "Hệ thống cảnh báo hoạt động", key: "test", forceSpeech: true) }

    private func alert(strong: Bool, message: String, key: String, forceSpeech: Bool = false) {
        activateWarningAudio()
        let volume = warningVolume
        player?.currentTime = 0; player?.volume = strong ? min(volume * 1.15, 1) : volume; player?.play()
        if vibrationEnabled { AudioServicesPlaySystemSound(kSystemSoundID_Vibrate) }
        guard audioMode == .allWarnings else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard forceSpeech || key != lastSpokenKey || now - lastSpeechAt >= 5 else { return }
        if speechSynthesizer.isSpeaking { speechSynthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN"); utterance.rate = 0.50; utterance.volume = volume
        speechSynthesizer.speak(utterance); lastSpokenKey = key; lastSpeechAt = now
    }

    private func activateWarningAudio() {
        let session = AVAudioSession.sharedInstance()
        // Mix only: Ivy must not duck/pause music, CarPlay or tweak audio sessions.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func releaseWarningAudioIfIdle() {
        guard player?.isPlaying != true, !speechSynthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { releaseWarningAudioIfIdle() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { releaseWarningAudioIfIdle() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { releaseWarningAudioIfIdle() }

    private static func makeBeepWAV() -> Data {
        let sampleRate = 22_050, duration = 0.18, frequency = 880.0
        let count = Int(Double(sampleRate) * duration); var pcm = Data(capacity: count * 2)
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate), fade = min(1.0, min(t / 0.02, (duration - t) / 0.04))
            let sample = sin(2 * .pi * frequency * t) * 0.32 * max(0, fade)
            var value = Int16(max(-1, min(1, sample)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func ascii(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ x: UInt32) { var v = x.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { var v = x.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + pcm.count)); ascii("WAVE"); ascii("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16); ascii("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
