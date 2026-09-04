import AVFoundation
import Combine
import CoreMedia

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var fps: Double = 0

    let frameProcessor = FrameProcessor()

    private let sessionQueue = DispatchQueue(label: "ivy.camera.session")
    private let videoQueue = DispatchQueue(label: "ivy.camera.video", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isConfigured = false
    private var wantsToRun = false
    private var frameCounter = 0
    private var fpsWindowStart = ProcessInfo.processInfo.systemUptime

    override init() {
        super.init()
        // Do NOT request permission or start AVCaptureSession here. Ivy normally uses
        // 70mai; constructing CameraManager must be completely passive.
    }

    func start() {
        wantsToRun = true
        requestAccessAndStart()
    }

    func requestAccessAndStart() {
        guard wantsToRun else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async { self.authorizationStatus = granted ? .authorized : .denied }
                if granted, self.wantsToRun { self.configureAndStart() }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                self.errorMessage = "Camera access is required for Ivy iPhone test mode."
            }
        @unknown default:
            DispatchQueue.main.async { self.errorMessage = "Unknown camera authorization state." }
        }
    }

    func stop() {
        wantsToRun = false
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false; self.fps = 0 }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self, self.wantsToRun else { return }
            if !self.isConfigured {
                do { try self.configureSession(); self.isConfigured = true }
                catch {
                    DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
                    return
                }
            }
            guard self.wantsToRun, !self.session.isRunning else { return }
            self.fpsWindowStart = ProcessInfo.processInfo.systemUptime
            self.frameCounter = 0
            self.session.startRunning()
            DispatchQueue.main.async { self.isRunning = true }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        // Video-only Ivy test mode must never reconfigure the application's shared
        // AVAudioSession. This prevents opening the camera from interrupting music,
        // CarPlay or audio-related tweaks.
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noBackCamera
        }
        frameProcessor.horizontalFieldOfViewDegrees = Double(camera.activeFormat.videoFieldOfView)
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            }
        }
    }

    private func updateFPS() {
        frameCounter += 1
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - fpsWindowStart
        guard elapsed >= 0.5 else { return }
        let measuredFPS = Double(frameCounter) / elapsed
        frameCounter = 0; fpsWindowStart = now
        DispatchQueue.main.async { [weak self] in self?.fps = measuredFPS }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        updateFPS(); frameProcessor.process(sampleBuffer: sampleBuffer)
    }
}

private enum CameraError: LocalizedError {
    case noBackCamera, cannotAddInput, cannotAddOutput
    var errorDescription: String? {
        switch self {
        case .noBackCamera: return "No rear camera is available."
        case .cannotAddInput: return "Unable to add the rear camera to the capture session."
        case .cannotAddOutput: return "Unable to create the camera frame output."
        }
    }
}
