import AVFoundation
import CoreMedia
import CoreVideo

final class FrameProcessor: ObservableObject {
    @Published private(set) var processedFrames: UInt64 = 0
    @Published private(set) var frameWidth: Int = 0
    @Published private(set) var frameHeight: Int = 0
    @Published private(set) var pipelineStatus = "FRAME PIPELINE READY"

    private var lastPublishedAt = ProcessInfo.processInfo.systemUptime

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // This is the single entry point for all future vision inference.
        // V0.3 will call the lead-vehicle model here; later versions can
        // fan the same frame into lane and SuperCombo runners.
        processedFrames &+= 1

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublishedAt >= 0.25 else { return }
        lastPublishedAt = now

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let count = processedFrames

        DispatchQueue.main.async { [weak self] in
            self?.frameWidth = width
            self?.frameHeight = height
            self?.processedFrames = count
            self?.pipelineStatus = "FRAME PIPELINE ACTIVE"
        }
    }
}
