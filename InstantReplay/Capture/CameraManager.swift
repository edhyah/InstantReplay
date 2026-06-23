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
    @ObservationIgnored private nonisolated(unsafe) var hasLoggedFirstSample = false

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
        debugLog("[Camera] setupSession position=\(capturePosition)")
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        // Add camera input based on current position
        let avPosition = avCapturePosition(for: capturePosition)
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition) else {
            debugLog("[Camera] no builtInWideAngleCamera for position=\(capturePosition)")
            captureSession.commitConfiguration()
            return
        }
        debugLog("[Camera] selected device=\(device.localizedName), uniqueID=\(device.uniqueID)")

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                debugLog("[Camera] canAddInput returned false")
            }
        } catch {
            debugLog("[Camera] failed to create/add input: \(describeNSError(error))")
            captureSession.commitConfiguration()
            return
        }

        // Add video data output with delegate wired up
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        } else {
            debugLog("[Camera] canAddOutput(videoData) returned false")
        }

        captureSession.commitConfiguration()

        // Configure 60fps — must find a format that supports it first
        configure60fps(for: device)
        logActiveFormat(for: device, context: "setup")
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
                debugLog("[Camera] configured active format for requestedFPS=\(fps), supportedRange=\(range.minFrameRate)-\(range.maxFrameRate)")
            } else {
                debugLog("[Camera] no format with >=60fps found; using default active format")
            }

            device.unlockForConfiguration()
        } catch {
            debugLog("[Camera] configure60fps failed, using default active format: \(describeNSError(error))")
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
                debugLog("[Camera] switchCamera no builtInWideAngleCamera for position=\(newPosition)")
                captureSession.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                } else {
                    debugLog("[Camera] switchCamera canAddInput returned false")
                }
            } catch {
                debugLog("[Camera] switchCamera failed to create/add input: \(describeNSError(error))")
                captureSession.commitConfiguration()
                return
            }

            captureSession.commitConfiguration()

            // Configure 60fps for the new device
            configure60fps(for: device)
            logActiveFormat(for: device, context: "switch")

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
            hasLoggedFirstSample = false
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
        hasLoggedFirstSample = false
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

    private nonisolated func logActiveFormat(for device: AVCaptureDevice, context: String) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
            .map { String(format: "%.1f-%.1f", $0.minFrameRate, $0.maxFrameRate) }
            .joined(separator: ",")
        debugLog("[Camera] activeFormat context=\(context), dims=\(dimensions.width)x\(dimensions.height), minFrameDuration=\(device.activeVideoMinFrameDuration.seconds), maxFrameDuration=\(device.activeVideoMaxFrameDuration.seconds), ranges=[\(ranges)]")
    }

    private nonisolated func describeNSError(_ error: Error?) -> String {
        guard let error else { return "none" }
        let nsError = error as NSError
        return "domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), userInfo=\(nsError.userInfo)"
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if !hasLoggedFirstSample {
            hasLoggedFirstSample = true
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let dimensions = CMSampleBufferGetFormatDescription(sampleBuffer)
                .map(CMVideoFormatDescriptionGetDimensions)
            let dimensionsDescription = dimensions
                .map { "\($0.width)x\($0.height)" } ?? "unknown"
            debugLog("[Camera] first sample position=\(capturePosition), pts=\(timestamp.seconds), dims=\(dimensionsDescription), connectionOrientationSupported=\(connection.isVideoOrientationSupported), rotationAngleSupported0=\(connection.isVideoRotationAngleSupported(0)), mirrored=\(connection.isVideoMirrored)")
        }

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
