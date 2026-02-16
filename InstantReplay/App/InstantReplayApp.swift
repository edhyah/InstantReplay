import SwiftUI

@main
struct InstantReplayApp: App {
    @State private var cameraManager = CameraManager()
    @State private var hasEnteredForeground = false
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
                if hasEnteredForeground {
                    cameraManager.resetForForeground()
                }
                hasEnteredForeground = true
                cameraManager.configure()
                cameraManager.start()
            default:
                break
            }
        }
    }
}
