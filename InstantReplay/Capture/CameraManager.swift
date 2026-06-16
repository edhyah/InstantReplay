import AVFoundation

struct DetectionUpdate: Sendable {
    let trackingResult: BodyTrackingResult
    let stateMachineDebug: StateMachineDebugInfo
    let detectionFlash: Bool
    let captureFPS: Double
}

enum CameraPosition {
    case front
    case back
}

@Observable
final class CameraManager: NSObject, MediaSourceSession {
    nonisolated(unsafe) let captureSession = AVCaptureSession()
    let rollingBuffer = RollingBufferManager()
    let detectionCoordinator = DetectionCoordinator(
        label: "com.edwardahn.InstantReplay.cameraDetection",
        samplingPolicy: .minimumInterval(1.0 / CaptureConstants.poseDetectionFPS)
    )
    private let sessionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.camera", qos: .userInitiated)

    @ObservationIgnored nonisolated(unsafe) var onDetectionUpdate: (@Sendable (DetectionUpdate) -> Void)?
    @ObservationIgnored nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?

    private(set) var currentPosition: CameraPosition = .back
    @ObservationIgnored private nonisolated(unsafe) var capturePosition: CameraPosition = .back

    private var isConfigured = false
    @ObservationIgnored private nonisolated(unsafe) var captureWindowFrameCount: Int = 0
    @ObservationIgnored private nonisolated(unsafe) var captureWindowStartTime: CFTimeInterval = 0
    @ObservationIgnored private nonisolated(unsafe) var measuredCaptureFPS: Double = 0

    override init() {
        super.init()
        detectionCoordinator.onDetectionUpdate = { [weak self] update in
            self?.onDetectionUpdate?(update)
        }
        detectionCoordinator.onMovementDetected = { [weak self] event in
            self?.onMovementDetected?(event)
        }
    }

    func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        sessionQueue.async { [self] in
            self.setupSession()
        }
    }

    nonisolated private func setupSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        // Add camera input based on current position
        let avPosition = avCapturePosition(for: capturePosition)
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition) else {
            captureSession.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
        } catch {
            captureSession.commitConfiguration()
            return
        }

        // Add video data output with delegate wired up
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        captureSession.commitConfiguration()

        // Configure 60fps — must find a format that supports it first
        configure60fps(for: device)
    }

    nonisolated private func configure60fps(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            var bestFormat: AVCaptureDevice.Format?
            var bestFrameRateRange: AVFrameRateRange?

            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate >= 60 {
                        if bestFrameRateRange == nil || range.maxFrameRate > bestFrameRateRange!.maxFrameRate {
                            bestFormat = format
                            bestFrameRateRange = range
                        }
                    }
                }
            }

            if let format = bestFormat, let range = bestFrameRateRange {
                device.activeFormat = format
                let fps = min(range.maxFrameRate, 60)
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            }

            device.unlockForConfiguration()
        } catch {
            // Fall back to default frame rate
        }
    }

    func switchCamera() {
        sessionQueue.async { [self] in
            captureSession.beginConfiguration()

            // Remove current camera input
            for input in captureSession.inputs {
                if let deviceInput = input as? AVCaptureDeviceInput,
                   deviceInput.device.hasMediaType(.video) {
                    captureSession.removeInput(deviceInput)
                }
            }

            // Toggle position
            let newPosition = toggledPosition(from: capturePosition)
            let avPosition = avCapturePosition(for: newPosition)

            // Add new camera input
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition) else {
                captureSession.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                }
            } catch {
                captureSession.commitConfiguration()
                return
            }

            captureSession.commitConfiguration()

            // Configure 60fps for the new device
            configure60fps(for: device)

            // Update position on main thread (Observable property)
            DispatchQueue.main.async {
                self.currentPosition = newPosition
            }
            capturePosition = newPosition

            // Reset detection pipeline and rolling buffer (old frames are from different camera)
            detectionCoordinator.reset()
            rollingBuffer.reset()
            rollingBuffer.setFrontCamera(isFrontCamera(newPosition))
            captureWindowFrameCount = 0
            captureWindowStartTime = 0
            measuredCaptureFPS = 0
        }
    }

    func start() {
        sessionQueue.async { [self] in
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            self.rollingBuffer.stop()
        }
    }

    func resetForForeground() {
        rollingBuffer.reset()
        detectionCoordinator.reset()
        captureWindowFrameCount = 0
        captureWindowStartTime = 0
        measuredCaptureFPS = 0
        isConfigured = false
    }

    func extractClip(jumpTimestamp: CMTime, completion: @escaping @Sendable (ClipAsset?) -> Void) {
        ClipExtractor(rollingBuffer: rollingBuffer).extractClip(
            jumpTimestamp: jumpTimestamp,
            completion: completion
        )
    }

    private nonisolated func toggledPosition(from position: CameraPosition) -> CameraPosition {
        switch position {
        case .front: .back
        case .back: .front
        }
    }

    private nonisolated func avCapturePosition(for position: CameraPosition) -> AVCaptureDevice.Position {
        switch position {
        case .front: .front
        case .back: .back
        }
    }

    private nonisolated func isFrontCamera(_ position: CameraPosition) -> Bool {
        switch position {
        case .front: true
        case .back: false
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Forward every frame to the rolling buffer for disk recording
        rollingBuffer.append(sampleBuffer)

        // Measure capture FPS over a rolling 1-second window
        let captureNow = CACurrentMediaTime()
        captureWindowFrameCount += 1
        let windowElapsed = captureNow - captureWindowStartTime
        if windowElapsed >= 1.0 {
            measuredCaptureFPS = Double(captureWindowFrameCount) / windowElapsed
            captureWindowFrameCount = 0
            captureWindowStartTime = captureNow
        }

        detectionCoordinator.process(
            sampleBuffer: sampleBuffer,
            metadata: FrameMetadata(isFrontCamera: isFrontCamera(capturePosition)),
            measuredFPS: measuredCaptureFPS
        )
    }
}
