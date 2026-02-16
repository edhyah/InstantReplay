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

    func attachToLayer(_ layer: AVPlayerLayer) {
        playerLayer = layer
        if let player {
            layer.player = player
        }
    }

    /// Replaces the current clip with a new one. Hard-cuts immediately.
    func playClip(_ clipAsset: ClipAsset) {
        // Tear down previous looper/player
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

        playerLayer?.player = queuePlayer
        queuePlayer.rate = CaptureConstants.defaultPlaybackRate
    }

    func stop() {
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player = nil
        hasClip = false
        playerLayer?.player = nil
    }
}
