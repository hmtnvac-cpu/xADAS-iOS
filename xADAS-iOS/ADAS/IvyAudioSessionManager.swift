import AVFoundation
import Foundation

/// Single owner for Ivy's AVAudioSession configuration.
/// Keeps external music/audio mixing and prevents Ivy modules from repeatedly
/// changing/deactivating the shared session underneath one another.
final class IvyAudioSessionManager {
    static let shared = IvyAudioSessionManager()
    private let session = AVAudioSession.sharedInstance()
    private let lock = NSLock()
    private var recordingClients = 0
    private var playbackClients = 0
    private init() {}

    func beginPlayback() {
        lock.lock(); playbackClients += 1; lock.unlock()
        applyCurrentMode()
    }

    func endPlayback() {
        lock.lock(); playbackClients = max(0, playbackClients - 1); lock.unlock()
        applyCurrentMode()
    }

    func beginRecording() throws {
        lock.lock(); recordingClients += 1; lock.unlock()
        do { try applyCurrentModeThrowing() }
        catch {
            lock.lock(); recordingClients = max(0, recordingClients - 1); lock.unlock()
            throw error
        }
    }

    func endRecording() {
        lock.lock(); recordingClients = max(0, recordingClients - 1); lock.unlock()
        applyCurrentMode()
    }

    private func counts() -> (recording: Int, playback: Int) {
        lock.lock(); defer { lock.unlock() }
        return (recordingClients, playbackClients)
    }

    private func applyCurrentMode() { try? applyCurrentModeThrowing() }

    private func applyCurrentModeThrowing() throws {
        let state = counts()
        if state.recording > 0 {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
            try session.setActive(true)
        } else if state.playback > 0 {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } else {
            // Do not deactivate here. Other apps and another Ivy audio client may be
            // transitioning at the same moment; leaving the mixed session active avoids
            // needless interruption/restart of external audio.
        }
    }
}
