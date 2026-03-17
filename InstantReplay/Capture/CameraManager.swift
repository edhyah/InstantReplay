import AVFoundation

struct DetectionUpdate: Sendable {
    let trackingResult: BodyTrackingResult
    let stateMachineDebug: StateMachineDebugInfo
    let detectionFlash: Bool
    let captureFPS: Double
}

@Observable
final class CameraManager: NSObject {
    nonisolated(unsafe) let captureSession = AVCaptureSession()
    let rollingBuffer = RollingBufferManager()
    let detectionPipeline = DetectionPipeline()
    private let sessionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.camera", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.detection", qos: .userInitiated)

    nonisolated(unsafe) var onDetectionUpdate: (@Sendable (DetectionUpdate) -> Void)?
    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?

    private var isConfigured = false
    private nonisolated(unsafe) var frameCounter: Int = 0
    private nonisolated(unsafe) var captureWindowFrameCount: Int = 0
    private nonisolated(unsafe) var captureWindowStartTime: CFTimeInterval = 0
    private nonisolated(unsafe) var measuredCaptureFPS: Double = 0

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
        detectionPipeline.reset()
        frameCounter = 0
        captureWindowFrameCount = 0
        captureWindowStartTime = 0
        measuredCaptureFPS = 0
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

        // Measure capture FPS over a rolling 1-second window
        let captureNow = CACurrentMediaTime()
        captureWindowFrameCount += 1
        let windowElapsed = captureNow - captureWindowStartTime
        if windowElapsed >= 1.0 {
            measuredCaptureFPS = Double(captureWindowFrameCount) / windowElapsed
            captureWindowFrameCount = 0
            captureWindowStartTime = captureNow
        }

        // Subsample frames for pose estimation
        frameCounter += 1
        if frameCounter % CaptureConstants.poseSubsamplingRate == 0 {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            nonisolated(unsafe) let buffer = pixelBuffer
            detectionQueue.async { [self] in
                self.detectionPipeline.onMovementDetected = { [self] event in
                    self.onMovementDetected?(event)
                }

                self.detectionPipeline.onDetectionResult = { [self] result in
                    let update = DetectionUpdate(
                        trackingResult: result.trackingResult,
                        stateMachineDebug: result.stateMachineDebug,
                        detectionFlash: result.didDetectMovement,
                        captureFPS: self.measuredCaptureFPS
                    )
                    self.onDetectionUpdate?(update)
                }

                self.detectionPipeline.processFrame(buffer, timestamp: timestamp)
            }
        }
    }
}
