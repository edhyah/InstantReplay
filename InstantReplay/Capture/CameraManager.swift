import AVFoundation

@Observable
final class CameraManager: NSObject {
    nonisolated(unsafe) let captureSession = AVCaptureSession()
    let rollingBuffer = RollingBufferManager()
    let poseEstimator = PoseEstimator()
    let bodyTracker = BodyTracker()
    private let sessionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.camera", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.detection", qos: .userInitiated)

    nonisolated(unsafe) var onDetectionUpdate: (@Sendable (BodyTrackingResult) -> Void)?

    private var isConfigured = false
    private nonisolated(unsafe) var frameCounter: Int = 0

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

        // Add rear camera input
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
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
        bodyTracker.reset()
        frameCounter = 0
        isConfigured = false
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

        // Subsample frames for pose estimation
        frameCounter += 1
        if frameCounter % CaptureConstants.poseSubsamplingRate == 0 {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            nonisolated(unsafe) let buffer = pixelBuffer
            detectionQueue.async { [self] in
                let observations = self.poseEstimator.estimatePoses(buffer)
                let trackingResult = self.bodyTracker.update(with: observations)
                self.onDetectionUpdate?(trackingResult)
            }
        }
    }
}
