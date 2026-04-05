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
    private var displayLink: CADisplayLink?
    private var videoAsset: AVAsset?
    private var currentVideoURL: URL?

    private let processingQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.videoProcessing", qos: .userInitiated)
    private let detectionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.videoDetection", qos: .userInitiated)

    private var frameCounter: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var fpsWindowStartTime: CFTimeInterval = 0
    private var fpsWindowFrameCount: Int = 0
    private var playbackStartTime: CFTimeInterval = 0
    private var videoStartTimestamp: CMTime = .zero
    private var currentFrameBuffer: CMSampleBuffer?
    private var currentFrameTimestamp: CMTime = .zero
    private var currentFrameAdjustedTimestamp: CMTime = .zero

    // Calculate subsampling rate based on video frame rate to achieve ~15fps detection
    private var poseSubsamplingRate: Int {
        max(1, Int(round(Double(videoFrameRate) / 15.0)))
    }

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
        }

        detectionPipeline.reset()
        frameCounter = 0
        fpsWindowStartTime = 0
        fpsWindowFrameCount = 0
        measuredFPS = 0
        playbackStartTime = 0
        videoStartTimestamp = .zero
        currentFrameBuffer = nil
        currentFrameTimestamp = .zero
        currentFrameAdjustedTimestamp = .zero
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
                }
            } catch {
                debugLog("[VideoFileProcessor] Failed to setup reader: \(error)")
            }
        }
    }

    private func startDisplayLink() {
        displayLink?.invalidate()

        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        // Run at max refresh rate to handle high frame rate videos
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrameTime = CACurrentMediaTime()
        fpsWindowStartTime = lastFrameTime
        playbackStartTime = lastFrameTime
        videoStartTimestamp = .zero
        debugLog("[VideoFileProcessor] displayLink started, videoFrameRate=\(videoFrameRate)")
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard isPlaying else { return }

        processingQueue.async { [weak self] in
            self?.processNextFrame()
        }
    }

    private func processNextFrame() {
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

        // Calculate target video time based on elapsed real time
        let currentTime = CACurrentMediaTime()
        let elapsedRealTime = currentTime - playbackStartTime
        let targetVideoTime = CMTime(seconds: elapsedRealTime, preferredTimescale: 600)

        // If we already have a frame that's at or past the target time, reuse it
        // This prevents consuming frames too fast for low frame rate videos
        if currentFrameBuffer != nil && CMTimeCompare(currentFrameAdjustedTimestamp, targetVideoTime) >= 0 {
            // Current frame is still valid for this target time, reuse it
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(currentFrameBuffer!) else { return }
            displayFrame(pixelBuffer: pixelBuffer, timestamp: currentFrameTimestamp, currentTime: currentTime)
            return
        }

        // Read frames until we catch up to the target time
        while true {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                debugLog("[VideoFileProcessor] processNextFrame: no more sample buffers, video ended")
                DispatchQueue.main.async { [weak self] in
                    self?.handlePlaybackComplete()
                }
                return
            }

            let frameTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Track the first frame's timestamp to handle videos that don't start at 0
            if videoStartTimestamp == .zero {
                videoStartTimestamp = frameTimestamp
                playbackStartTime = currentTime  // Reset playback start to sync with first frame
            }

            let adjustedTimestamp = CMTimeSubtract(frameTimestamp, videoStartTimestamp)

            // If this frame is at or past the target time, use it
            if CMTimeCompare(adjustedTimestamp, targetVideoTime) >= 0 {
                currentFrameBuffer = sampleBuffer
                currentFrameTimestamp = frameTimestamp
                currentFrameAdjustedTimestamp = adjustedTimestamp
                break
            }

            // Otherwise, continue reading (skip this frame)
            frameCounter += 1
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(currentFrameBuffer!) else { return }
        displayFrame(pixelBuffer: pixelBuffer, timestamp: currentFrameTimestamp, currentTime: currentTime)
    }

    private func displayFrame(pixelBuffer: CVPixelBuffer, timestamp: CMTime, currentTime: CFTimeInterval) {

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

        // Notify all frame observers
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for callback in self.frameObservers.values {
                callback(pixelBuffer)
            }
        }

        // Subsample for pose detection
        frameCounter += 1
        if frameCounter % poseSubsamplingRate == 0 {
            detectionQueue.async { [weak self] in
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

    private func handlePlaybackComplete() {
        // Loop the video by restarting playback
        restartPlayback()
    }

    /// Extracts a clip around the landing timestamp from the video file.
    func extractClip(landingTimestamp: CMTime, completion: @escaping (ClipAsset?) -> Void) {
        guard let url = currentVideoURL else {
            completion(nil)
            return
        }

        let preRoll = CaptureConstants.clipPreRollDuration
        let postRoll = CaptureConstants.clipPostRollDuration

        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let videoTrack = tracks.first else {
                    await MainActor.run { completion(nil) }
                    return
                }

                // Use the video track's natural time scale for consistent timing
                let naturalTimeScale = try await videoTrack.load(.naturalTimeScale)

                let clipStart = CMTimeSubtract(landingTimestamp, CMTimeMakeWithSeconds(preRoll, preferredTimescale: naturalTimeScale))
                let clipEnd = CMTimeAdd(landingTimestamp, CMTimeMakeWithSeconds(postRoll, preferredTimescale: naturalTimeScale))

                // Clamp to valid range (start >= 0)
                let clampedStart = CMTimeMaximum(clipStart, CMTime(value: 0, timescale: naturalTimeScale))
                let duration = CMTimeSubtract(clipEnd, clampedStart)

                guard CMTimeGetSeconds(duration) >= 0.5 else {
                    debugLog("[VideoFileProcessor] clip too short, returning nil")
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

                // Set the composition track's natural time scale to match the source
                compositionTrack.naturalTimeScale = naturalTimeScale

                let timeRange = CMTimeRangeMake(start: clampedStart, duration: duration)
                try compositionTrack.insertTimeRange(timeRange, of: videoTrack, at: CMTime(value: 0, timescale: naturalTimeScale))

                let clipAsset = ClipAsset(
                    asset: composition,
                    timeRange: CMTimeRangeMake(start: CMTime(value: 0, timescale: naturalTimeScale), duration: duration),
                    referencedURLs: [url],
                    clipOriginTime: clampedStart
                )

                await MainActor.run { completion(clipAsset) }
            } catch {
                debugLog("[VideoFileProcessor] failed to extract clip: \(error)")
                await MainActor.run { completion(nil) }
            }
        }
    }
}
