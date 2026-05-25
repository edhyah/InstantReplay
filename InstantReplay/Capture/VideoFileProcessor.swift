import AVFoundation
import CoreMedia
import CoreVideo

@Observable
final class VideoFileProcessor: NSObject {
    let detectionPipeline = DetectionPipeline()

    nonisolated(unsafe) var onDetectionUpdate: (@Sendable (DetectionUpdate) -> Void)?
    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?
    nonisolated(unsafe) var onPlaybackComplete: (() -> Void)?

    private var frameObservers: [ObjectIdentifier: (CVPixelBuffer) -> Void] = [:]

    func addFrameObserver(_ observer: AnyObject, callback: @escaping (CVPixelBuffer) -> Void) {
        frameObservers[ObjectIdentifier(observer)] = callback
    }

    func removeFrameObserver(_ observer: AnyObject) {
        frameObservers.removeValue(forKey: ObjectIdentifier(observer))
    }

    private(set) var isPlaying: Bool = false
    private(set) var videoFrameRate: Float = 30.0
    private(set) var measuredFPS: Double = 0

    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var pendingSampleBuffer: CMSampleBuffer?
    private var displayLink: CADisplayLink?
    private var videoAsset: AVAsset?
    private var currentVideoURL: URL?
    private var firstSampleTimestamp: CMTime?
    private var playbackStartWallTime: CFTimeInterval?
    private var reachedEndAfterCurrentFrame: Bool = false

    private let processingQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.videoProcessing", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.videoDetection", qos: .userInitiated)

    private var frameCounter: Int = 0
    private var lastDetectionTimestamp: CMTime?
    private var lastFrameTime: CFTimeInterval = 0
    private var fpsWindowStartTime: CFTimeInterval = 0
    private var fpsWindowFrameCount: Int = 0

    private let targetPoseDetectionInterval: TimeInterval = 1.0 / 15.0

    func loadVideo(url: URL, completion: @escaping (Bool) -> Void) {
        let asset = AVAsset(url: url)

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    await MainActor.run { completion(false) }
                    return
                }

                let frameRate = try await videoTrack.load(.nominalFrameRate)

                await MainActor.run {
                    self.currentVideoURL = url
                    self.videoAsset = asset
                    self.videoFrameRate = frameRate
                    completion(true)
                }
            } catch {
                await MainActor.run { completion(false) }
            }
        }
    }

    func start() {
        guard let asset = videoAsset else {
            debugLog("[VideoFileProcessor] start() called but no videoAsset")
            return
        }
        debugLog("[VideoFileProcessor] start() called, videoFrameRate=\(videoFrameRate)")

        processingQueue.async { [weak self] in
            self?.setupReader(for: asset)

            DispatchQueue.main.async {
                debugLog("[VideoFileProcessor] starting display link, trackOutput ready: \(self?.trackOutput != nil)")
                self?.isPlaying = true
                self?.startDisplayLink()
            }
        }
    }

    func stop() {
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil

        processingQueue.async { [weak self] in
            self?.assetReader?.cancelReading()
            self?.assetReader = nil
            self?.trackOutput = nil
            self?.pendingSampleBuffer = nil
            self?.firstSampleTimestamp = nil
            self?.playbackStartWallTime = nil
            self?.reachedEndAfterCurrentFrame = false
        }

        detectionPipeline.reset()
        frameCounter = 0
        lastDetectionTimestamp = nil
        fpsWindowStartTime = 0
        fpsWindowFrameCount = 0
        measuredFPS = 0
    }

    func reset() {
        stop()
        videoAsset = nil
        currentVideoURL = nil
    }

    func restartPlayback() {
        stop()
        guard let url = currentVideoURL else { return }
        let asset = AVAsset(url: url)
        videoAsset = asset
        start()
    }

    private func setupReader(for asset: AVAsset) {
        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else { return }

                let reader = try AVAssetReader(asset: asset)

                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]

                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                output.alwaysCopiesSampleData = false

                if reader.canAdd(output) {
                    reader.add(output)
                }

                reader.startReading()
                debugLog("[VideoFileProcessor] setupReader: reader started, status=\(reader.status.rawValue)")

                await MainActor.run {
                    debugLog("[VideoFileProcessor] setupReader complete, assigning trackOutput")
                    self.assetReader = reader
                    self.trackOutput = output
                    self.pendingSampleBuffer = nil
                    self.firstSampleTimestamp = nil
                    self.playbackStartWallTime = nil
                    self.reachedEndAfterCurrentFrame = false
                    self.lastDetectionTimestamp = nil
                }
            } catch {
                debugLog("[VideoFileProcessor] Failed to setup reader: \(error)")
            }
        }
    }

    private func startDisplayLink() {
        displayLink?.invalidate()

        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        // Tick at least 30 Hz so low-fps videos still render smoothly while media timestamps decide when frames advance.
        let preferredRate = max(30, videoFrameRate)
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: preferredRate,
            preferred: preferredRate
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTime = CACurrentMediaTime()
        fpsWindowStartTime = lastFrameTime
        debugLog("[VideoFileProcessor] displayLink started, preferredRate=\(videoFrameRate)")
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard isPlaying else { return }

        processingQueue.async { [weak self] in
            self?.processNextFrame()
        }
    }

    private func processNextFrame() {
        if reachedEndAfterCurrentFrame {
            DispatchQueue.main.async { [weak self] in
                self?.handlePlaybackComplete()
            }
            return
        }

        guard let output = trackOutput else {
            // Reader not ready yet - don't restart, just skip this frame
            if frameCounter == 0 {
                debugLog("[VideoFileProcessor] processNextFrame: trackOutput is nil (reader not ready)")
            }
            return
        }

        guard let reader = assetReader, reader.status == .reading else {
            let status = assetReader?.status.rawValue ?? -1
            debugLog("[VideoFileProcessor] processNextFrame: reader not reading, status=\(status)")
            if let error = assetReader?.error {
                debugLog("[VideoFileProcessor] reader error: \(error)")
            }
            DispatchQueue.main.async { [weak self] in
                self?.handlePlaybackComplete()
            }
            return
        }

        let wallNow = CACurrentMediaTime()
        var latestDueSample: CMSampleBuffer?

        if firstSampleTimestamp == nil {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                debugLog("[VideoFileProcessor] processNextFrame: no more sample buffers, video ended")
                DispatchQueue.main.async { [weak self] in
                    self?.handlePlaybackComplete()
                }
                return
            }

            firstSampleTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            playbackStartWallTime = wallNow
            latestDueSample = sampleBuffer
        } else {
            guard let firstSampleTimestamp,
                  let playbackStartWallTime else {
                return
            }

            let playbackElapsed = wallNow - playbackStartWallTime
            var sampleBuffer = pendingSampleBuffer ?? output.copyNextSampleBuffer()
            pendingSampleBuffer = nil

            while let sample = sampleBuffer {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                let sampleElapsed = CMTimeGetSeconds(CMTimeSubtract(timestamp, firstSampleTimestamp))

                if sampleElapsed > playbackElapsed {
                    pendingSampleBuffer = sample
                    break
                }

                latestDueSample = sample
                sampleBuffer = output.copyNextSampleBuffer()

                if sampleBuffer == nil {
                    reachedEndAfterCurrentFrame = true
                }
            }
        }

        guard let sampleBuffer = latestDueSample else {
            return
        }

        displayAndDetect(sampleBuffer)
    }

    private func displayAndDetect(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Update FPS measurement
        let now = CACurrentMediaTime()
        fpsWindowFrameCount += 1
        let windowElapsed = now - fpsWindowStartTime
        if windowElapsed >= 1.0 {
            let fps = Double(fpsWindowFrameCount) / windowElapsed
            DispatchQueue.main.async { [weak self] in
                self?.measuredFPS = fps
            }
            fpsWindowFrameCount = 0
            fpsWindowStartTime = now
        }

        // Notify all frame observers with the frame that is due at the current media time.
        let displaySampleBuffer = sampleBuffer
        DispatchQueue.main.async { [weak self] in
            _ = displaySampleBuffer
            guard let self = self else { return }
            for callback in self.frameObservers.values {
                callback(pixelBuffer)
            }
        }

        frameCounter += 1
        if shouldRunPoseDetection(at: timestamp) {
            lastDetectionTimestamp = timestamp
            let detectionSampleBuffer = sampleBuffer
            detectionQueue.async { [weak self] in
                _ = detectionSampleBuffer
                guard let self = self else { return }

                self.detectionPipeline.onMovementDetected = { [weak self] event in
                    self?.onMovementDetected?(event)
                }

                self.detectionPipeline.onDetectionResult = { [weak self] result in
                    guard let self = self else { return }
                    let update = DetectionUpdate(
                        trackingResult: result.trackingResult,
                        stateMachineDebug: result.stateMachineDebug,
                        detectionFlash: result.didDetectMovement,
                        captureFPS: self.measuredFPS
                    )
                    self.onDetectionUpdate?(update)
                }

                self.detectionPipeline.processFrame(pixelBuffer, timestamp: timestamp)
            }
        }
    }

    private func shouldRunPoseDetection(at timestamp: CMTime) -> Bool {
        guard let lastDetectionTimestamp else {
            return true
        }

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(timestamp, lastDetectionTimestamp))
        return elapsed >= targetPoseDetectionInterval
    }

    private func handlePlaybackComplete() {
        // Loop the video by restarting playback
        restartPlayback()
    }

    /// Extracts a clip around the jump timestamp from the video file.
    func extractClip(jumpTimestamp: CMTime, completion: @escaping (ClipAsset?) -> Void) {
        guard let url = currentVideoURL else {
            completion(nil)
            return
        }

        let preRoll = CaptureConstants.clipPreRollDuration
        let postRoll = CaptureConstants.clipPostRollDuration

        let clipStart = CMTimeSubtract(jumpTimestamp, CMTimeMakeWithSeconds(preRoll, preferredTimescale: jumpTimestamp.timescale))
        let clipEnd = CMTimeAdd(jumpTimestamp, CMTimeMakeWithSeconds(postRoll, preferredTimescale: jumpTimestamp.timescale))

        // Clamp to valid range (start >= 0)
        let clampedStart = CMTimeMaximum(clipStart, .zero)
        let duration = CMTimeSubtract(clipEnd, clampedStart)

        guard CMTimeGetSeconds(duration) >= 0.5 else {
            debugLog("[VideoFileProcessor] clip too short, returning nil")
            completion(nil)
            return
        }

        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    await MainActor.run { completion(nil) }
                    return
                }

                guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    await MainActor.run { completion(nil) }
                    return
                }

                let timeRange = CMTimeRangeMake(start: clampedStart, duration: duration)
                try compositionTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

                let clipAsset = ClipAsset(
                    asset: composition,
                    timeRange: CMTimeRangeMake(start: .zero, duration: duration),
                    referencedURLs: [url]
                )

                await MainActor.run { completion(clipAsset) }
            } catch {
                debugLog("[VideoFileProcessor] failed to extract clip: \(error)")
                await MainActor.run { completion(nil) }
            }
        }
    }
}
