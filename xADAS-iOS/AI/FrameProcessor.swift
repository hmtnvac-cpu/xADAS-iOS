import AVFoundation
import Combine
import CoreMedia
import CoreVideo

final class FrameProcessor: ObservableObject {
    @Published private(set) var processedFrames: UInt64 = 0
    @Published private(set) var frameWidth: Int = 0
    @Published private(set) var frameHeight: Int = 0
    @Published private(set) var pipelineStatus = "FRAME PIPELINE READY"

    private var totalFrames: UInt64 = 0
    private var lastPublishedAt = ProcessInfo.processInfo.systemUptime

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Single entry point for future inference modules.
        // V0.3 will attach lead-vehicle detection here. Lane and
        // SuperCombo runners can consume the same CVPixelBuffer later.
        totalFrames &+= 1

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishedAt >= 0.25 else { return }
        lastPublishedAt = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let count = totalFrames

        DispatchQueue.main.async { [weak self] in
            self?.frameWidth = width
            self?.frameHeight = height
            self?.processedFrames = count
            self?.pipelineStatus = "FRAME PIPELINE ACTIVE"
        }
    }
}
