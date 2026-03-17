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

    func updateUIView(_ uiView: PiPContainerView, context: Context) {}
}

class PiPContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
    }
}
