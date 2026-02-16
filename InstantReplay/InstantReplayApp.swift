import SwiftUI

@main
struct InstantReplayApp: App {
    @State private var cameraManager = CameraManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(cameraManager: cameraManager)
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .background:
                cameraManager.stop()
            case .active:
                cameraManager.configure()
                cameraManager.start()
            default:
                break
            }
        }
    }
}
