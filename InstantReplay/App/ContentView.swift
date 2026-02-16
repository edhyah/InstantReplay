import AVFoundation
import SwiftUI

struct ContentView: View {
    let cameraManager: CameraManager
    @State private var trackingResult: BodyTrackingResult?

    var body: some View {
        CameraPreviewView(cameraManager: cameraManager, trackingResult: trackingResult)
            .ignoresSafeArea()
            .persistentSystemOverlays(.hidden)
            .statusBarHidden()
            .onAppear {
                setupDetectionCallback()
                requestCameraAccess()
            }
            .onDisappear {
                cameraManager.stop()
            }
    }

    private func setupDetectionCallback() {
        cameraManager.onDetectionUpdate = { result in
            DispatchQueue.main.async {
                self.trackingResult = result
            }
        }
    }

    private func requestCameraAccess() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                cameraManager.configure()
                cameraManager.start()
            }
        }
    }
}
