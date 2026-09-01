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

    private let sessionQueue = DispatchQueue(label: "xadas.camera.session")
    private let videoQueue = DispatchQueue(label: "xadas.camera.video", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private var isConfigured = false

    private var frameCounter = 0
    private var fpsWindowStart = ProcessInfo.processInfo.systemUptime

    override init() {
        super.init()
        requestAccessAndStart()
    }

    func requestAccessAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationStatus = granted ? .authorized : .denied
                }
                if granted {
                    self?.configureAndStart()
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
                self.errorMessage = "Camera access is required for xADAS."
            }
        @unknown default:
            DispatchQueue.main.async {
                self.errorMessage = "Unknown camera authorization state."
            }
        }
    }

    func start() {
        configureAndStart()
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
                self.fps = 0
            }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                do {
                    try self.configureSession()
                    self.isConfigured = true
                } catch {
                    DispatchQueue.main.async {
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
            }

            if !self.session.isRunning {
                self.fpsWindowStart = ProcessInfo.processInfo.systemUptime
                self.frameCounter = 0
                self.session.startRunning()
                DispatchQueue.main.async { self.isRunning = true }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noBackCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
    }

    private func updateFPS() {
        frameCounter += 1
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - fpsWindowStart

        guard elapsed >= 0.5 else { return }

        let measuredFPS = Double(frameCounter) / elapsed
        frameCounter = 0
        fpsWindowStart = now

        DispatchQueue.main.async { [weak self] in
            self?.fps = measuredFPS
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        updateFPS()
        frameProcessor.process(sampleBuffer: sampleBuffer)
    }
}

private enum CameraError: LocalizedError {
    case noBackCamera
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noBackCamera:
            return "No rear camera is available."
        case .cannotAddInput:
            return "Unable to add the rear camera to the capture session."
        case .cannotAddOutput:
            return "Unable to create the camera frame output."
        }
    }
}
