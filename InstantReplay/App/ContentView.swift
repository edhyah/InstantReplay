import AVFoundation
import SwiftUI

struct ContentView: View {
    let cameraManager: CameraManager
    @State private var detectionUpdate: DetectionUpdate?
    @State private var debugOverlayVisible: Bool = true
    @State private var replayManager = ReplayManager()
    @State private var showingReplay: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Camera preview is always present (behind replay when replaying)
            CameraPreviewView(
                cameraManager: cameraManager,
                detectionUpdate: detectionUpdate,
                debugOverlayVisible: debugOverlayVisible && !showingReplay
            )
            .ignoresSafeArea()

            // Replay layer on top when a clip is available
            if showingReplay {
                ReplayPlayerView(replayManager: replayManager)
                    .ignoresSafeArea()
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .onTapGesture(count: 3) {
            debugOverlayVisible.toggle()
        }
        .onAppear {
            setupDetectionCallback()
            setupMovementCallback()
            requestCameraAccess()
        }
        .onDisappear {
            cameraManager.stop()
            replayManager.stop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Reset to pre-first-detection state on foreground
                replayManager.stop()
                showingReplay = false
                cameraManager.rollingBuffer.clearReplayReference()
            }
        }
    }

    private func setupDetectionCallback() {
        cameraManager.onDetectionUpdate = { update in
            DispatchQueue.main.async {
                self.detectionUpdate = update
            }
        }
    }

    private func setupMovementCallback() {
        let extractor = ClipExtractor(rollingBuffer: cameraManager.rollingBuffer)

        cameraManager.onMovementDetected = { event in
            print("[Replay] onMovementDetected fired, landingTimestamp=\(event.landingTimestamp.seconds)")

            let segments = cameraManager.rollingBuffer.segments
            print("[Replay] segments count: \(segments.count)")
            for (i, seg) in segments.enumerated() {
                print("[Replay]   segment[\(i)]: start=\(seg.startTimestamp.seconds), end=\(seg.endTimestamp?.seconds ?? -1), url=\(seg.fileURL.lastPathComponent)")
            }

            let allURLs = Set(segments.map { $0.fileURL })
            cameraManager.rollingBuffer.markReplayReference(allURLs)

            extractor.extractClip(landingTimestamp: event.landingTimestamp) { clipAsset in
                if let clip = clipAsset {
                    print("[Replay] clip extracted, duration=\(clip.timeRange.duration.seconds), refs=\(clip.referencedURLs.count)")
                } else {
                    print("[Replay] clip extraction returned nil")
                }

                DispatchQueue.main.async {
                    if let clip = clipAsset {
                        cameraManager.rollingBuffer.markReplayReference(clip.referencedURLs)
                        replayManager.playClip(clip)
                        showingReplay = true
                        print("[Replay] showingReplay set to true")
                    } else {
                        cameraManager.rollingBuffer.clearReplayReference()
                        print("[Replay] no clip, cleared references")
                    }
                }
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
