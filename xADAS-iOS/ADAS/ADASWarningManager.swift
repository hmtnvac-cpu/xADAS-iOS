import AVFoundation
import AudioToolbox
import Foundation

final class ADASWarningManager {
    private var player: AVAudioPlayer?
    private var lastDistanceAlertAt: TimeInterval = 0
    private var lastLaneAlertAt: TimeInterval = 0
    private var lastDistanceRisk: LeadDistanceRisk = .unavailable
    private var lastLaneState: LaneDepartureState = .unavailable

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(data: Self.makeBeepWAV())
        player?.prepareToPlay()
    }

    func update(distance: LeadDistanceState, lane: LaneDepartureState) {
        let now = ProcessInfo.processInfo.systemUptime

        if distance.risk == .danger,
           (lastDistanceRisk != .danger || now - lastDistanceAlertAt >= 2.0) {
            alert(strong: true)
            lastDistanceAlertAt = now
        } else if distance.risk == .caution,
                  lastDistanceRisk != .caution,
                  now - lastDistanceAlertAt >= 1.2 {
            alert(strong: false)
            lastDistanceAlertAt = now
        }
        lastDistanceRisk = distance.risk

        let laneWarning = lane == .warningLeft || lane == .warningRight
        let previousLaneWarning = lastLaneState == .warningLeft || lastLaneState == .warningRight
        if laneWarning,
           (!previousLaneWarning || lane != lastLaneState || now - lastLaneAlertAt >= 3.0) {
            alert(strong: false)
            lastLaneAlertAt = now
        }
        lastLaneState = lane
    }

    private func alert(strong: Bool) {
        player?.currentTime = 0
        player?.volume = strong ? 1.0 : 0.65
        player?.play()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
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
