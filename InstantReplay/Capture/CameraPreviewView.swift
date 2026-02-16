import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let cameraManager: CameraManager
    let trackingResult: BodyTrackingResult?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = cameraManager.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.skeletonOverlay.trackingResult = trackingResult
        uiView.skeletonOverlay.previewLayer = uiView.previewLayer
    }
}

class PreviewContainerView: UIView {
    let skeletonOverlay = SkeletonOverlayView()

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(skeletonOverlay)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(skeletonOverlay)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        skeletonOverlay.frame = bounds
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
    }
}
