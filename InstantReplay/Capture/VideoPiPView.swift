import AVFoundation
import SwiftUI
import UIKit

struct VideoPiPView: UIViewRepresentable {
    let videoProcessor: VideoFileProcessor

    func makeUIView(context: Context) -> VideoPiPContainerView {
        let view = VideoPiPContainerView()
        view.videoProcessor = videoProcessor
        return view
    }

    func updateUIView(_ uiView: VideoPiPContainerView, context: Context) {}
}

class VideoPiPContainerView: UIView {
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        frameImageView.frame = bounds
    }

    private func setupFrameCallback() {
        videoProcessor?.addFrameObserver(self) { [weak self] pixelBuffer in
            self?.displayFrame(pixelBuffer)
        }
    }

    deinit {
        videoProcessor?.removeFrameObserver(self)
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
