import AVFoundation
import PhotosUI
import SwiftUI

enum InputMode {
    case camera
    case video
}

struct ContentView: View {
    let cameraManager: CameraManager
    @State private var detectionUpdate: DetectionUpdate?
    @State private var debugOverlayVisible: Bool = true
    @State private var replayManager = ReplayManager()
    @State private var showingReplay: Bool = false
    @State private var replayAvailable: Bool = false
    @State private var controlsVisible: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    // Video input mode
    @State private var inputMode: InputMode = .camera
    @State private var videoProcessor = VideoFileProcessor()
    @State private var showingVideoPicker: Bool = false
    @State private var videoLoaded: Bool = false

    var body: some View {
        ZStack {
            // Input layer: Camera or Video
            if inputMode == .camera {
                CameraPreviewView(
                    cameraManager: cameraManager,
                    detectionUpdate: detectionUpdate,
                    debugOverlayVisible: debugOverlayVisible && !showingReplay
                )
                .ignoresSafeArea()
            } else {
                VideoPreviewView(
                    videoProcessor: videoProcessor,
                    detectionUpdate: detectionUpdate,
                    debugOverlayVisible: debugOverlayVisible
                )
                .ignoresSafeArea()
            }

            // Replay layer on top when showing replay (camera mode only)
            if showingReplay && inputMode == .camera {
                ReplayPlayerView(replayManager: replayManager)
                    .ignoresSafeArea()
            }

            // Playback controls overlay (only when replay is available, camera mode only)
            if replayAvailable && inputMode == .camera {
                PlaybackControlsView(
                    replayManager: replayManager,
                    showingReplay: $showingReplay,
                    visible: $controlsVisible
                )
                .ignoresSafeArea()
            }

            // Mode toggle button (upper right)
            VStack {
                HStack {
                    Spacer()
                    modeToggleButton
                        .padding(.trailing, 20)
                        .padding(.top, 20)
                }
                Spacer()
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .onAppear {
            setupDetectionCallback()
            setupMovementCallback()
            requestCameraAccess()
        }
        .onDisappear {
            cameraManager.stop()
            videoProcessor.stop()
            replayManager.stop()
        }
        .onChange(of: showingReplay) { _, showing in
            if showing {
                replayManager.resume()
            } else {
                replayManager.pause()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Reset to pre-first-detection state on foreground
                replayManager.stop()
                showingReplay = false
                replayAvailable = false
                controlsVisible = false
                cameraManager.rollingBuffer.clearReplayReference()
            }
        }
        .sheet(isPresented: $showingVideoPicker) {
            VideoPickerView { url in
                loadVideo(url: url)
            }
        }
    }

    private var modeToggleButton: some View {
        Button(action: toggleMode) {
            Image(systemName: inputMode == .camera ? "folder.badge.plus" : "xmark.circle.fill")
                .font(.title2)
                .foregroundColor(.white)
                .padding(12)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
    }

    private func toggleMode() {
        if inputMode == .camera {
            // Switch to video mode
            cameraManager.stop()
            showingVideoPicker = true
        } else {
            // Switch back to camera mode
            videoProcessor.stop()
            videoLoaded = false
            inputMode = .camera
            detectionUpdate = nil
            requestCameraAccess()
        }
    }

    private func loadVideo(url: URL) {
        videoProcessor.loadVideo(url: url) { success in
            if success {
                inputMode = .video
                videoLoaded = true
                setupVideoDetectionCallback()
                videoProcessor.start()
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

    private func setupVideoDetectionCallback() {
        videoProcessor.onDetectionUpdate = { update in
            DispatchQueue.main.async {
                self.detectionUpdate = update
            }
        }

        videoProcessor.onMovementDetected = { event in
            print("[Video] Movement detected at timestamp=\(event.landingTimestamp.seconds)")
        }

        videoProcessor.onPlaybackComplete = {
            print("[Video] Playback complete")
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

            if let firstSeg = segments.first {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(event.landingTimestamp, firstSeg.startTimestamp))
                if elapsed < 1.0 {
                    print("[Replay] buffer too short (\(elapsed)s), skipping")
                    return
                }
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
                        replayAvailable = true
                        controlsVisible = false
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

// MARK: - Video Picker

struct VideoPickerView: UIViewControllerRepresentable {
    let onVideoSelected: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPickerView

        init(_ parent: VideoPickerView) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()

            guard let result = results.first else { return }

            if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    guard let url = url else { return }

                    // Copy to a temporary location since the provided URL is temporary
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)

                    do {
                        try FileManager.default.copyItem(at: url, to: tempURL)
                        DispatchQueue.main.async {
                            self.parent.onVideoSelected(tempURL)
                        }
                    } catch {
                        print("[VideoPicker] Failed to copy video: \(error)")
                    }
                }
            }
        }
    }
}
