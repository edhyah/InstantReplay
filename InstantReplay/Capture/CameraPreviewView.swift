import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let cameraManager: CameraManager
    let detectionUpdate: DetectionUpdate?
    let debugOverlayVisible: Bool

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = cameraManager.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        uiView.skeletonOverlay.isHidden = !debugOverlayVisible
        if let update = detectionUpdate {
            uiView.skeletonOverlay.trackingResult = update.trackingResult
            uiView.skeletonOverlay.stateMachineDebug = update.stateMachineDebug
            uiView.skeletonOverlay.captureFPS = update.captureFPS
            if update.detectionFlash {
                uiView.skeletonOverlay.detectionFlash = true
            }
        }
        uiView.skeletonOverlay.previewLayer = uiView.previewLayer
        uiView.skeletonOverlay.isFrontCamera = cameraManager.currentPosition == .front

        // Update camera position for rotation and mirroring
        uiView.cameraPosition = cameraManager.currentPosition
    }
}

class PreviewContainerView: UIView {
    let skeletonOverlay = SkeletonOverlayView()

    var cameraPosition: CameraPosition = .back {
        didSet {
            updateConnectionSettings()
        }
    }

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
        updateConnectionSettings()
    }

    private func updateConnectionSettings() {
        guard let connection = previewLayer.connection else { return }

        // Set rotation angle - front camera needs 180 to appear right-side up
        let rotationAngle: CGFloat = cameraPosition == .front ? 180 : 0
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        // Keep camera footage in real-world orientation so live capture matches imported videos.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}
