import AVFoundation
import SwiftUI
import UIKit

struct VideoPreviewView: UIViewRepresentable {
    let videoProcessor: VideoFileProcessor
    let detectionUpdate: DetectionUpdate?
    let debugOverlayVisible: Bool

    func makeUIView(context: Context) -> VideoContainerView {
        let view = VideoContainerView()
        view.videoProcessor = videoProcessor
        return view
    }

    func updateUIView(_ uiView: VideoContainerView, context: Context) {
        uiView.skeletonOverlay.isHidden = !debugOverlayVisible
        if let update = detectionUpdate {
            uiView.skeletonOverlay.trackingResult = update.trackingResult
            uiView.skeletonOverlay.stateMachineDebug = update.stateMachineDebug
            uiView.skeletonOverlay.captureFPS = update.captureFPS
            if update.detectionFlash {
                uiView.skeletonOverlay.detectionFlash = true
            }
        }
    }
}

class VideoContainerView: UIView {
    let skeletonOverlay = SkeletonOverlayView()
    private let frameImageView = UIImageView()
    private var ciContext = CIContext()

    weak var videoProcessor: VideoFileProcessor? {
        didSet {
            setupFrameCallback()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black

        frameImageView.contentMode = .scaleAspectFill
        frameImageView.clipsToBounds = true
        addSubview(frameImageView)

        // Configure skeleton overlay to use simple coordinate conversion (no previewLayer)
        skeletonOverlay.previewLayer = nil
        addSubview(skeletonOverlay)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        frameImageView.frame = bounds
        skeletonOverlay.frame = bounds
    }

    private func setupFrameCallback() {
        videoProcessor?.onFrameReady = { [weak self] pixelBuffer in
            self?.displayFrame(pixelBuffer)
        }
    }

    private func displayFrame(_ pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
            let uiImage = UIImage(cgImage: cgImage)
            DispatchQueue.main.async {
                self.frameImageView.image = uiImage
            }
        }
    }
}
