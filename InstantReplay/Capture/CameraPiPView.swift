import AVFoundation
import SwiftUI

struct CameraPiPView: UIViewRepresentable {
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> PiPContainerView {
        let view = PiPContainerView()
        view.previewLayer.session = cameraManager.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PiPContainerView, context: Context) {
        uiView.cameraPosition = cameraManager.currentPosition
    }
}

class PiPContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    var cameraPosition: CameraPosition = .back {
        didSet {
            updateConnectionSettings()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateConnectionSettings()
    }

    private func updateConnectionSettings() {
        guard let connection = previewLayer.connection else { return }

        // Set rotation angle - front camera needs 180 to appear right-side up
        let rotationAngle: CGFloat = cameraPosition == .front ? 180 : 0
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }

        // Set mirroring - front camera should be mirrored for selfie mode
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = cameraPosition == .front
        }
    }
}
