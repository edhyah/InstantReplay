import AVFoundation
import SwiftUI

struct ContentView: View {
    let cameraManager: CameraManager
    @State private var poseObservations: [BodyObservation] = []

    var body: some View {
        CameraPreviewView(cameraManager: cameraManager, observations: poseObservations)
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
        cameraManager.onDetectionUpdate = { observations in
            DispatchQueue.main.async {
                self.poseObservations = observations
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
