import AVFoundation
import SwiftUI

struct ReplayPlayerView: UIViewRepresentable {
    let replayManager: ReplayManager

    func makeUIView(context: Context) -> ReplayContainerView {
        debugLog("[ReplayPlayerView] makeUIView called")
        let view = ReplayContainerView()
        replayManager.attachToLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: ReplayContainerView, context: Context) {
        // Re-attach on updates in case player changed
        debugLog("[ReplayPlayerView] updateUIView called, re-attaching layer")
        replayManager.attachToLayer(uiView.playerLayer)
    }
}

class ReplayContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspectFill
        backgroundColor = .black
    }
}

/// Manages AVQueuePlayer + AVPlayerLooper for gapless looping replay.
@MainActor
@Observable
final class ReplayManager {
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private(set) var hasClip: Bool = false
    private(set) var isPlaying: Bool = false
    private(set) var currentRate: Float = CaptureConstants.defaultPlaybackRate
    private(set) var clipDuration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var clipCapturedAt: Date? = nil
    private var clipStartTime: CMTime = .zero
    private var timeObserver: Any?
    private var playerStatusObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var layerReadinessObservation: NSKeyValueObservation?

    func attachToLayer(_ layer: AVPlayerLayer) {
        debugLog("[ReplayManager] attachToLayer called")
        debugLog("[ReplayManager]   layer=\(layer)")
        debugLog("[ReplayManager]   player=\(String(describing: player))")
        debugLog("[ReplayManager]   layer.superlayer=\(String(describing: layer.superlayer))")
        playerLayer = layer
        if let player {
            layer.player = player
            debugLog("[ReplayManager]   assigned player to layer")
        } else {
            debugLog("[ReplayManager]   no player to assign yet")
        }
    }

    /// Replaces the current clip with a new one. Hard-cuts immediately.
    func playClip(_ clipAsset: ClipAsset) {
        debugLog("[ReplayManager] playClip called")
        debugLog("[ReplayManager]   playerLayer is nil: \(playerLayer == nil)")
        debugLog("[ReplayManager]   clipAsset.timeRange=\(clipAsset.timeRange.start.seconds)-\(clipAsset.timeRange.end.seconds)")

        // Tear down previous looper/player
        removeTimeObserver()
        removeStatusObservers()
        looper?.disableLooping()
        looper = nil
        player?.pause()

        let templateItem = AVPlayerItem(asset: clipAsset.asset)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true

        let playerLooper = AVPlayerLooper(
            player: queuePlayer,
            templateItem: templateItem,
            timeRange: clipAsset.timeRange
        )

        player = queuePlayer
        looper = playerLooper
        hasClip = true
        isPlaying = true
        clipCapturedAt = Date()
        clipStartTime = clipAsset.timeRange.start
        clipDuration = clipAsset.timeRange.duration.seconds
        currentRate = CaptureConstants.defaultPlaybackRate

        // Add status observers before assigning to layer
        addStatusObservers(player: queuePlayer, item: templateItem)

        debugLog("[ReplayManager]   assigning player to playerLayer")
        playerLayer?.player = queuePlayer
        queuePlayer.rate = CaptureConstants.defaultPlaybackRate

        debugLog("[ReplayManager]   player.status=\(queuePlayer.status.rawValue) (0=unknown, 1=readyToPlay, 2=failed)")
        debugLog("[ReplayManager]   item.status=\(templateItem.status.rawValue)")
        if queuePlayer.status == .failed {
            debugLog("[ReplayManager]   player.error=\(String(describing: queuePlayer.error))")
        }
        if templateItem.status == .failed {
            debugLog("[ReplayManager]   item.error=\(String(describing: templateItem.error))")
        }

        addTimeObserver()
    }

    func stop() {
        debugLog("[ReplayManager] stop called")
        removeTimeObserver()
        removeStatusObservers()
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player = nil
        hasClip = false
        isPlaying = false
        clipCapturedAt = nil
        clipDuration = 0
        currentTime = 0
        currentRate = CaptureConstants.defaultPlaybackRate
        playerLayer?.player = nil
    }

    // MARK: - Playback Controls

    func setRate(_ rate: Float) {
        currentRate = rate
        if isPlaying {
            player?.rate = rate
        }
    }

    func stepForward() {
        pause()
        player?.currentItem?.step(byCount: 1)
    }

    func stepBackward() {
        pause()
        player?.currentItem?.step(byCount: -1)
    }

    func seek(to fraction: Double) {
        guard clipDuration > 0 else { return }
        let targetSeconds = clipStartTime.seconds + fraction * clipDuration
        seek(toClipSeconds: targetSeconds)
    }

    func seek(toClipSeconds seconds: Double) {
        guard clipDuration > 0 else { return }
        let clampedSeconds = max(clipStartTime.seconds, min(clipStartTime.seconds + clipDuration, seconds))
        let targetTime = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.rate = currentRate
        isPlaying = true
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    // MARK: - Status Observation

    private func addStatusObservers(player: AVQueuePlayer, item: AVPlayerItem) {
        // Observe player status
        playerStatusObservation = player.observe(\.status, options: [.new, .old]) { [weak self] player, change in
            Task { @MainActor in
                guard self != nil else { return }
                let statusString = Self.statusString(player.status)
                debugLog("[ReplayManager] player.status changed to \(statusString)")
                if player.status == .failed {
                    debugLog("[ReplayManager]   player.error=\(String(describing: player.error))")
                }
            }
        }

        // Observe item status
        itemStatusObservation = item.observe(\.status, options: [.new, .old]) { [weak self] item, change in
            Task { @MainActor in
                guard self != nil else { return }
                let statusString = Self.itemStatusString(item.status)
                debugLog("[ReplayManager] item.status changed to \(statusString)")
                if item.status == .failed {
                    debugLog("[ReplayManager]   item.error=\(String(describing: item.error))")
                }
            }
        }

        // Observe layer readiness
        if let layer = playerLayer {
            layerReadinessObservation = layer.observe(\.isReadyForDisplay, options: [.new, .old]) { [weak self] layer, change in
                Task { @MainActor in
                    guard self != nil else { return }
                    debugLog("[ReplayManager] layer.isReadyForDisplay changed to \(layer.isReadyForDisplay)")
                }
            }
            debugLog("[ReplayManager]   initial layer.isReadyForDisplay=\(layer.isReadyForDisplay)")
        }
    }

    private func removeStatusObservers() {
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        layerReadinessObservation?.invalidate()
        layerReadinessObservation = nil
    }

    private static func statusString(_ status: AVPlayer.Status) -> String {
        switch status {
        case .unknown: return "unknown(0)"
        case .readyToPlay: return "readyToPlay(1)"
        case .failed: return "failed(2)"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func itemStatusString(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: return "unknown(0)"
        case .readyToPlay: return "readyToPlay(1)"
        case .failed: return "failed(2)"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    // MARK: - Time Observation

    private func addTimeObserver() {
        guard let player else { return }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = time.seconds - self.clipStartTime.seconds
                self.currentTime = max(0, min(elapsed, self.clipDuration))
            }
        }
    }

    private func removeTimeObserver() {
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
    }
}

@MainActor
@Observable
final class ComparisonReplayManager {
    let live = ReplayManager()
    let reference = ReplayManager()

    private(set) var referenceOffset: TimeInterval = 0
    private(set) var clipDuration: Double = 0
    private(set) var currentRate: Float = CaptureConstants.defaultPlaybackRate
    private var liveSyncPoint: Double = CaptureConstants.clipPreRollDuration
    private var referenceSyncPoint: Double = CaptureConstants.clipPreRollDuration
    private var timelineStart: Double = -CaptureConstants.clipPreRollDuration
    private var timelineEnd: Double = CaptureConstants.clipPostRollDuration
    private var liveDuration: Double = 0
    private var referenceDuration: Double = 0
    private var liveLoopStart: Double = 0
    private var referenceLoopStart: Double = 0
    private var sourceLiveClip: ClipAsset?
    private var sourceReferenceClip: ClipAsset?

    var isPlaying: Bool {
        live.isPlaying
    }

    var currentTime: Double {
        max(0, min(clipDuration, live.currentTime))
    }

    var clipCapturedAt: Date? {
        live.clipCapturedAt
    }

    func play(liveClip: ClipAsset, referenceClip: ClipAsset) {
        sourceLiveClip = liveClip
        sourceReferenceClip = referenceClip
        liveSyncPoint = liveClip.syncPoint.seconds
        referenceSyncPoint = referenceClip.syncPoint.seconds
        liveDuration = liveClip.timeRange.duration.seconds
        referenceDuration = referenceClip.timeRange.duration.seconds
        currentRate = CaptureConstants.defaultPlaybackRate

        playAlignedClips(startAt: 0, shouldResume: true)
    }

    func stop() {
        live.stop()
        reference.stop()
        referenceOffset = 0
        clipDuration = 0
        currentRate = CaptureConstants.defaultPlaybackRate
        liveDuration = 0
        referenceDuration = 0
        liveLoopStart = 0
        referenceLoopStart = 0
        sourceLiveClip = nil
        sourceReferenceClip = nil
    }

    func pause() {
        live.pause()
        reference.pause()
    }

    func resume() {
        live.resume()
        reference.resume()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }

    func setRate(_ rate: Float) {
        currentRate = rate
        live.setRate(rate)
        reference.setRate(rate)
    }

    func stepForward() {
        pause()
        let nextTime = min(clipDuration, currentTime + 1.0 / 30.0)
        seek(toComparisonSeconds: nextTime)
    }

    func stepBackward() {
        pause()
        let nextTime = max(0, currentTime - 1.0 / 30.0)
        seek(toComparisonSeconds: nextTime)
    }

    func seek(to fraction: Double) {
        guard clipDuration > 0 else { return }
        seek(toComparisonSeconds: max(0, min(1, fraction)) * clipDuration)
    }

    func nudgeReference(by delta: TimeInterval) {
        let comparisonSeconds = currentTime
        let wasPlaying = isPlaying
        referenceOffset += delta
        playAlignedClips(startAt: comparisonSeconds, shouldResume: wasPlaying)
    }

    func resetReferenceOffset() {
        let comparisonSeconds = currentTime
        let wasPlaying = isPlaying
        referenceOffset = 0
        playAlignedClips(startAt: comparisonSeconds, shouldResume: wasPlaying)
    }

    private func seek(toComparisonSeconds seconds: Double) {
        let clampedSeconds = max(0, min(clipDuration, seconds))
        live.seek(toClipSeconds: liveLoopStart + clampedSeconds)
        reference.seek(toClipSeconds: referenceLoopStart + clampedSeconds)
    }

    private func playAlignedClips(startAt seconds: Double, shouldResume: Bool) {
        guard let sourceLiveClip,
              let sourceReferenceClip else {
            return
        }

        updateTimelineBounds()
        guard clipDuration > 0 else { return }

        liveLoopStart = liveSyncPoint + timelineStart
        referenceLoopStart = referenceSyncPoint + timelineStart - referenceOffset

        let duration = CMTime(seconds: clipDuration, preferredTimescale: 600)
        let alignedLiveClip = ClipAsset(
            asset: sourceLiveClip.asset,
            timeRange: CMTimeRange(
                start: CMTime(seconds: liveLoopStart, preferredTimescale: 600),
                duration: duration
            ),
            referencedURLs: sourceLiveClip.referencedURLs,
            syncPoint: CMTime(seconds: -timelineStart, preferredTimescale: 600)
        )
        let alignedReferenceClip = ClipAsset(
            asset: sourceReferenceClip.asset,
            timeRange: CMTimeRange(
                start: CMTime(seconds: referenceLoopStart, preferredTimescale: 600),
                duration: duration
            ),
            referencedURLs: sourceReferenceClip.referencedURLs,
            syncPoint: CMTime(seconds: -timelineStart + referenceOffset, preferredTimescale: 600)
        )

        live.playClip(alignedLiveClip)
        reference.playClip(alignedReferenceClip)
        setRate(currentRate)
        seek(toComparisonSeconds: seconds)

        if shouldResume {
            resume()
        } else {
            pause()
        }
    }

    private func updateTimelineBounds() {
        timelineStart = max(-liveSyncPoint, -referenceSyncPoint + referenceOffset)
        timelineEnd = min(liveDuration - liveSyncPoint, referenceDuration - referenceSyncPoint + referenceOffset)
        clipDuration = max(0, timelineEnd - timelineStart)
    }
}
