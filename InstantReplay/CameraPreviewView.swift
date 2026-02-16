import AVFoundation
import SwiftUI

struct CameraPreviewView: UIViewRepresentable {
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> UIView {
        let view = PreviewLayerView()
        view.previewLayer.session = cameraManager.captureSession
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private class PreviewLayerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection,
           connection.isVideoRotationAngleSupported(0) {
            connection.videoRotationAngle = 0
        }
    }
}
