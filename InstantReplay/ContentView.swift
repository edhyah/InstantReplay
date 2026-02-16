import AVFoundation
import SwiftUI

struct ContentView: View {
    let cameraManager: CameraManager

    var body: some View {
        CameraPreviewView(cameraManager: cameraManager)
            .ignoresSafeArea()
            .persistentSystemOverlays(.hidden)
            .statusBarHidden()
            .onAppear {
                requestCameraAccess()
            }
            .onDisappear {
                cameraManager.stop()
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
