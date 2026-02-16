import AVFoundation
import SwiftUI

struct ReplayPlayerView: UIViewRepresentable {
    let replayManager: ReplayManager

    func makeUIView(context: Context) -> ReplayContainerView {
        let view = ReplayContainerView()
        replayManager.attachToLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: ReplayContainerView, context: Context) {}
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

    func attachToLayer(_ layer: AVPlayerLayer) {
        playerLayer = layer
        if let player {
            layer.player = player
        }
    }

    /// Replaces the current clip with a new one. Hard-cuts immediately.
    func playClip(_ clipAsset: ClipAsset) {
        // Tear down previous looper/player
        removeTimeObserver()
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

        playerLayer?.player = queuePlayer
        queuePlayer.rate = CaptureConstants.defaultPlaybackRate

        addTimeObserver()
    }

    func stop() {
        removeTimeObserver()
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
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
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
