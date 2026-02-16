import AVFoundation
import SwiftUI

struct ContentView: View {
    let cameraManager: CameraManager
    @State private var detectionUpdate: DetectionUpdate?
    @State private var debugOverlayVisible: Bool = true

    var body: some View {
        CameraPreviewView(
            cameraManager: cameraManager,
            detectionUpdate: detectionUpdate,
            debugOverlayVisible: debugOverlayVisible
        )
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .onTapGesture(count: 3) {
            debugOverlayVisible.toggle()
        }
        .onAppear {
            setupDetectionCallback()
            requestCameraAccess()
        }
        .onDisappear {
            cameraManager.stop()
        }
    }

    private func setupDetectionCallback() {
        cameraManager.onDetectionUpdate = { update in
            DispatchQueue.main.async {
                self.detectionUpdate = update
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
