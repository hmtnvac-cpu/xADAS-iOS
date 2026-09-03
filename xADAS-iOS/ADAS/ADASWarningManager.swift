import AVFoundation
import AudioToolbox
import Combine
import Foundation

final class ADASWarningManager: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let volumeKey = "xadas.warning.volume"
    static let vibrationKey = "xadas.warning.vibration"
    static let minimumActiveSpeedKPH = 60.0

    private var player: AVAudioPlayer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var lastDistanceAlertAt: TimeInterval = 0
    private var lastLaneAlertAt: TimeInterval = 0
    private var lastOverspeedAlertAt: TimeInterval = 0
    private var lastSpeechAt: TimeInterval = 0
    private var lastSpokenKey = ""
    private var lastDistanceRisk: LeadDistanceRisk = .unavailable
    private var lastLaneState: LaneDepartureState = .unavailable
    private var lastTrafficSignUpdatedAt: TimeInterval = 0
    private var lastTrafficSign: TrafficSignKind?

    override init() {
        super.init()
        if UserDefaults.standard.object(forKey: Self.volumeKey) == nil {
            UserDefaults.standard.set(0.35, forKey: Self.volumeKey)
        }
        if UserDefaults.standard.object(forKey: Self.vibrationKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.vibrationKey)
        }
        player = try? AVAudioPlayer(data: Self.makeBeepWAV())
        player?.delegate = self
        player?.prepareToPlay()
        speechSynthesizer.delegate = self
    }

    private var warningVolume: Float {
        Float(min(max(UserDefaults.standard.double(forKey: Self.volumeKey), 0), 1))
    }

    private var vibrationEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.vibrationKey)
    }

    /// Sign announcements are allowed while stationary so recognition can be tested.
    /// Lane/distance/overspeed driving warnings remain gated to >60 km/h as requested.
    func update(
        distance: LeadDistanceState,
        lane: LaneDepartureState,
        trafficSign: TrafficSignState,
        vehicleSpeedKPH: Double
    ) {
        announceNewTrafficSignIfNeeded(trafficSign)

        guard vehicleSpeedKPH > Self.minimumActiveSpeedKPH else {
            lastDistanceRisk = .unavailable
            lastLaneState = .unavailable
            return
        }

        let now = ProcessInfo.processInfo.systemUptime

        if let limit = trafficSign.explicitSpeedLimitKPH,
           vehicleSpeedKPH >= Double(limit) + 5.0,
           now - lastOverspeedAlertAt >= 6.0 {
            alert(
                strong: true,
                message: "Cảnh báo quá tốc độ. Giới hạn \(limit) ki lô mét một giờ",
                key: "overspeed-\(limit)"
            )
            lastOverspeedAlertAt = now
        }

        let distanceDangerDue = distance.risk == .danger
            && (lastDistanceRisk != .danger || now - lastDistanceAlertAt >= 2.0)
        let distanceCautionDue = distance.risk == .caution
            && lastDistanceRisk != .caution
            && now - lastDistanceAlertAt >= 1.2
        let laneWarning = lane == .warningLeft || lane == .warningRight
        let previousLaneWarning = lastLaneState == .warningLeft || lastLaneState == .warningRight
        let laneWarningDue = laneWarning
            && (!previousLaneWarning || lane != lastLaneState || now - lastLaneAlertAt >= 3.0)

        if distanceDangerDue {
            alert(strong: true, message: "Cảnh báo, khoảng cách quá gần", key: "distance-danger")
            lastDistanceAlertAt = now
        } else if laneWarningDue {
            let isLeft = lane == .warningLeft
            alert(
                strong: false,
                message: isLeft ? "Cảnh báo lệch làn trái" : "Cảnh báo lệch làn phải",
                key: isLeft ? "lane-left" : "lane-right"
            )
            lastLaneAlertAt = now
        } else if distanceCautionDue {
            alert(strong: false, message: "Chú ý khoảng cách", key: "distance-caution")
            lastDistanceAlertAt = now
        }
        lastDistanceRisk = distance.risk
        lastLaneState = lane
    }

    private func announceNewTrafficSignIfNeeded(_ state: TrafficSignState) {
        guard state.updatedAt > 0,
              state.updatedAt != lastTrafficSignUpdatedAt,
              let sign = state.lastConfirmedSign else { return }

        lastTrafficSignUpdatedAt = state.updatedAt
        guard sign != lastTrafficSign else { return }
        lastTrafficSign = sign

        switch sign {
        case .speedLimit(let value):
            alert(
                strong: false,
                message: "Giới hạn tốc độ \(value) ki lô mét một giờ",
                key: "sign-limit-\(value)",
                forceSpeech: true
            )
        case .denseAreaStart:
            alert(
                strong: false,
                message: "Bắt đầu khu đông dân cư",
                key: "sign-dense-start",
                forceSpeech: true
            )
        case .denseAreaEnd:
            alert(
                strong: false,
                message: "Hết khu đông dân cư",
                key: "sign-dense-end",
                forceSpeech: true
            )
        }
    }

    /// Settings test intentionally bypasses the >60 km/h gate.
    func testWarning() {
        alert(strong: true, message: "Hệ thống cảnh báo hoạt động", key: "test", forceSpeech: true)
    }

    private func alert(
        strong: Bool,
        message: String,
        key: String,
        forceSpeech: Bool = false
    ) {
        activateWarningAudio()
        let volume = warningVolume
        player?.currentTime = 0
        player?.volume = strong ? min(volume * 1.15, 1) : volume
        player?.play()
        if vibrationEnabled {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }

        let now = ProcessInfo.processInfo.systemUptime
        guard forceSpeech || key != lastSpokenKey || now - lastSpeechAt >= 5.0 else { return }

        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "vi-VN")
        utterance.rate = 0.50
        utterance.volume = volume
        speechSynthesizer.speak(utterance)
        lastSpokenKey = key
        lastSpeechAt = now
    }

    private func activateWarningAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
    }

    private func releaseWarningAudioIfIdle() {
        guard player?.isPlaying != true, !speechSynthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        releaseWarningAudioIfIdle()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        releaseWarningAudioIfIdle()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        releaseWarningAudioIfIdle()
    }

    private static func makeBeepWAV() -> Data {
        let sampleRate = 22_050
        let duration = 0.18
        let frequency = 880.0
        let count = Int(Double(sampleRate) * duration)
        var pcm = Data(capacity: count * 2)

        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let fade = min(1.0, min(t / 0.02, (duration - t) / 0.04))
            let sample = sin(2.0 * .pi * frequency * t) * 0.32 * max(0, fade)
            var value = Int16(max(-1, min(1, sample)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var data = Data()
        func appendASCII(_ string: String) { data.append(string.data(using: .ascii)!) }
        func appendUInt32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + pcm.count))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2)
        appendUInt16(16)
        appendASCII("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
