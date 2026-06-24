import AVFoundation
import PhotosUI
import SwiftUI

enum InputMode {
    case camera
    case video
}

enum VideoImportPurpose {
    case source
    case comparison
}

struct ContentView: View {
    let cameraManager: CameraManager
    @State private var detectionUpdate: DetectionUpdate?
    @State private var debugOverlayVisible: Bool = true
    @State private var replayManager = ReplayManager()
    @State private var comparisonReplayManager = ComparisonReplayManager()
    @State private var showingReplay: Bool = false
    @State private var replayAvailable: Bool = false
    @State private var comparisonReplayActive: Bool = false
    @State private var controlsVisible: Bool = false
    @State private var latestLiveClip: ClipAsset?
    @Environment(\.scenePhase) private var scenePhase

    // Video input mode
    @State private var inputMode: InputMode = .camera
    @State private var videoProcessor = VideoFileProcessor()
    @State private var showingVideoPicker: Bool = false
    @State private var videoImportPurpose: VideoImportPurpose = .source
    @State private var videoLoaded: Bool = false
    @State private var isLoadingVideo: Bool = false
    @State private var importError: String? = nil
    @State private var showDebugConsole: Bool = false
    @State private var comparisonVideoURL: URL?
    @State private var comparisonJumpTimestamp: CMTime?

    var body: some View {
        ZStack {
            // Black background for initial state (both modes, before detection)
            if !replayAvailable {
                Color.black
                    .ignoresSafeArea()
            }

            // Full-screen source view (when user taps PiP to return to source)
            if !showingReplay && replayAvailable {
                if inputMode == .camera {
                    CameraPreviewView(
                        cameraManager: cameraManager,
                        detectionUpdate: detectionUpdate,
                        debugOverlayVisible: debugOverlayVisible
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
            }

            // Detection/Replay layer on top when showing replay (both modes use ReplayPlayerView)
            if showingReplay {
                if comparisonReplayActive {
                    comparisonReplayView
                        .ignoresSafeArea()
                } else {
                    ReplayPlayerView(replayManager: replayManager)
                        .ignoresSafeArea()
                }
            }

            // Playback controls overlay for BOTH modes (shows PiP + import button)
            PlaybackControlsView(
                replayManager: replayManager,
                comparisonReplayManager: comparisonReplayManager,
                cameraManager: cameraManager,
                inputMode: inputMode,
                videoProcessor: inputMode == .video ? videoProcessor : nil,
                onImportTapped: { toggleMode() },
                onCompareTapped: { toggleComparisonMode() },
                showingReplay: $showingReplay,
                replayAvailable: replayAvailable,
                isComparisonReplay: comparisonReplayActive,
                comparisonVideoLoaded: comparisonVideoURL != nil,
                visible: $controlsVisible
            )
            .ignoresSafeArea()

            // Loading overlay for video import
            if isLoadingVideo {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    Text("Importing video...")
                        .foregroundColor(.white)
                        .font(.headline)
                }
            }

            // Debug console overlay
            if showDebugConsole {
                DebugConsoleView(isVisible: $showDebugConsole)
                    .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 3) {
            showDebugConsole.toggle()
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
        .onAppear {
            logDeviceInfo()
            setupDetectionCallback()
            setupMovementCallback()
            requestCameraAccess()
        }
        .onDisappear {
            cameraManager.stop()
            videoProcessor.stop()
            replayManager.stop()
            comparisonReplayManager.stop()
        }
        .onChange(of: showingReplay) { _, showing in
            if showing {
                if comparisonReplayActive {
                    comparisonReplayManager.resume()
                } else {
                    replayManager.resume()
                }
            } else {
                replayManager.pause()
                comparisonReplayManager.pause()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Reset to pre-first-detection state on foreground
                replayManager.stop()
                comparisonReplayManager.stop()
                showingReplay = false
                replayAvailable = false
                comparisonReplayActive = false
                latestLiveClip = nil
                controlsVisible = false
                cameraManager.rollingBuffer.clearReplayReference()
            }
        }
        .sheet(isPresented: $showingVideoPicker) {
            VideoPickerView(
                onVideoSelected: { url in
                    switch videoImportPurpose {
                    case .source:
                        loadVideo(url: url)
                    case .comparison:
                        loadComparisonVideo(url: url)
                    }
                },
                onLoadingStarted: {
                    isLoadingVideo = true
                },
                onLoadingFailed: { error in
                    isLoadingVideo = false
                    if !error.isEmpty {
                        importError = error
                    } else if videoImportPurpose == .source {
                        // User cancelled, return to camera
                        requestCameraAccess()
                    }
                }
            )
        }
        .alert("Import Failed", isPresented: .constant(importError != nil)) {
            Button("OK") {
                importError = nil
                requestCameraAccess()
            }
        } message: {
            Text(importError ?? "")
        }
    }

    private func toggleMode() {
        if inputMode == .camera {
            // Switch to video mode
            cameraManager.stop()
            videoImportPurpose = .source
            showingVideoPicker = true
        } else {
            // Switch back to camera mode
            videoProcessor.stop()
            videoLoaded = false
            inputMode = .camera
            detectionUpdate = nil
            showingReplay = false
            replayAvailable = false
            comparisonReplayActive = false
            latestLiveClip = nil
            requestCameraAccess()
        }
    }

    private var comparisonReplayView: some View {
        HStack(spacing: 1) {
            ReplayPlayerView(replayManager: comparisonReplayManager.live, videoGravity: .resizeAspect)
            ReplayPlayerView(replayManager: comparisonReplayManager.reference, videoGravity: .resizeAspect)
        }
        .background(Color.black)
    }

    private func importComparisonVideo() {
        videoImportPurpose = .comparison
        showingVideoPicker = true
    }

    private func toggleComparisonMode() {
        if comparisonReplayActive {
            exitComparisonReplay()
        } else {
            importComparisonVideo()
        }
    }

    private func exitComparisonReplay() {
        comparisonReplayManager.stop()
        comparisonReplayActive = false

        guard let latestLiveClip else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            replayManager.playClip(latestLiveClip)
        }
    }

    private func loadVideo(url: URL) {
        videoProcessor.loadVideo(url: url) { success in
            DispatchQueue.main.async {
                isLoadingVideo = false
                if success {
                    inputMode = .video
                    videoLoaded = true
                    showingReplay = false
                    replayAvailable = false
                    setupVideoDetectionCallback()
                    videoProcessor.start()
                } else {
                    importError = "Failed to load video file."
                }
            }
        }
    }

    private func loadComparisonVideo(url: URL) {
        comparisonVideoURL = nil
        comparisonJumpTimestamp = nil
        videoProcessor.detectFirstJump(in: url) { jumpTimestamp in
            DispatchQueue.main.async {
                isLoadingVideo = false
                guard let jumpTimestamp else {
                    importError = "No jump was detected in the comparison video."
                    return
                }

                comparisonVideoURL = url
                comparisonJumpTimestamp = jumpTimestamp
                debugLog("[Comparison] loaded reference video, jumpTimestamp=\(jumpTimestamp.seconds)")

                if let latestLiveClip {
                    showingReplay = true
                    replayAvailable = true
                    controlsVisible = false
                    playExtractedClip(latestLiveClip)
                }
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
            debugLog("[Video] Jump detected at timestamp=\(event.jumpTimestamp.seconds)")

            // Extract a clip around the detection timestamp
            videoProcessor.extractClip(jumpTimestamp: event.jumpTimestamp) { clipAsset in
                DispatchQueue.main.async {
                    if let clip = clipAsset {
                        debugLog("[Video] clip extracted, duration=\(clip.timeRange.duration.seconds)")
                        latestLiveClip = clip
                        // IMPORTANT: Set showingReplay first so SwiftUI creates ReplayPlayerView
                        // and attachToLayer is called before playClip tries to use playerLayer
                        showingReplay = true
                        replayAvailable = true
                        controlsVisible = false
                        playExtractedClip(clip)
                    } else {
                        debugLog("[Video] clip extraction returned nil")
                    }
                }
            }
        }
    }

    private func setupMovementCallback() {
        let extractor = ClipExtractor(rollingBuffer: cameraManager.rollingBuffer)

        cameraManager.onMovementDetected = { event in
            debugLog("[Replay] onMovementDetected fired, jumpTimestamp=\(event.jumpTimestamp.seconds)")

            let segments = cameraManager.rollingBuffer.segments
            debugLog("[Replay] segments count: \(segments.count)")
            for (i, seg) in segments.enumerated() {
                debugLog("[Replay]   segment[\(i)]: start=\(seg.startTimestamp.seconds), end=\(seg.endTimestamp?.seconds ?? -1), url=\(seg.fileURL.lastPathComponent)")
            }

            if let firstSeg = segments.first {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(event.jumpTimestamp, firstSeg.startTimestamp))
                if elapsed < 1.0 {
                    debugLog("[Replay] buffer too short (\(elapsed)s), skipping")
                    return
                }
            }

            let allURLs = Set(segments.map { $0.fileURL })
            cameraManager.rollingBuffer.markReplayReference(allURLs)

            extractor.extractClip(jumpTimestamp: event.jumpTimestamp) { clipAsset in
                if let clip = clipAsset {
                    debugLog("[Replay] clip extracted, duration=\(clip.timeRange.duration.seconds), refs=\(clip.referencedURLs.count)")
                } else {
                    debugLog("[Replay] clip extraction returned nil")
                }

                DispatchQueue.main.async {
                    if let clip = clipAsset {
                        cameraManager.rollingBuffer.markReplayReference(clip.referencedURLs)
                        latestLiveClip = clip
                        // IMPORTANT: Set showingReplay first so SwiftUI creates ReplayPlayerView
                        // and attachToLayer is called before playClip tries to use playerLayer
                        showingReplay = true
                        replayAvailable = true
                        controlsVisible = false
                        playExtractedClip(clip)
                    } else {
                        cameraManager.rollingBuffer.clearReplayReference()
                        debugLog("[Replay] no clip, cleared references")
                    }
                }
            }
        }
    }

    private func playExtractedClip(_ liveClip: ClipAsset) {
        latestLiveClip = liveClip

        guard let comparisonVideoURL,
              let comparisonJumpTimestamp else {
            comparisonReplayActive = false
            debugLog("[Replay] showingReplay set to true")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                replayManager.playClip(liveClip)
            }
            return
        }

        videoProcessor.extractClip(from: comparisonVideoURL, jumpTimestamp: comparisonJumpTimestamp) { referenceClip in
            DispatchQueue.main.async {
                guard let referenceClip else {
                    comparisonReplayActive = false
                    debugLog("[Comparison] reference clip extraction failed, falling back to single replay")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        replayManager.playClip(liveClip)
                    }
                    return
                }

                comparisonReplayActive = true
                debugLog("[Comparison] playing split replay")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    comparisonReplayManager.play(liveClip: liveClip, referenceClip: referenceClip)
                }
            }
        }
    }

    private func logDeviceInfo() {
        let device = UIDevice.current
        debugLog("[Build] diagnostics=writer-adaptor-v1")
        debugLog("[Device] model=\(device.model), systemVersion=\(device.systemVersion)")
        debugLog("[Device] name=\(device.name)")
        debugLog("[Device] systemName=\(device.systemName)")

        // Log machine identifier for more detail
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
        debugLog("[Device] machineIdentifier=\(identifier)")
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
    let onLoadingStarted: () -> Void
    let onLoadingFailed: (String) -> Void
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
            guard let result = results.first else {
                // User cancelled
                parent.dismiss()
                DispatchQueue.main.async {
                    self.parent.onLoadingFailed("")
                }
                return
            }

            // Dismiss picker and show loading indicator
            parent.dismiss()
            DispatchQueue.main.async {
                self.parent.onLoadingStarted()
            }

            if result.itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                result.itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                    if let error = error {
                        DispatchQueue.main.async {
                            self.parent.onLoadingFailed("Failed to load video: \(error.localizedDescription)")
                        }
                        return
                    }

                    guard let url = url else {
                        DispatchQueue.main.async {
                            self.parent.onLoadingFailed("Failed to load video file.")
                        }
                        return
                    }

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
                        DispatchQueue.main.async {
                            self.parent.onLoadingFailed("Failed to copy video: \(error.localizedDescription)")
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.parent.onLoadingFailed("Selected file is not a video.")
                }
            }
        }
    }
}
