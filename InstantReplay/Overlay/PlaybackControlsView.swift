import SwiftUI

struct PlaybackControlsView: View {
    let replayManager: ReplayManager
    let cameraManager: CameraManager
    let inputMode: InputMode
    let videoProcessor: VideoFileProcessor?
    let onImportTapped: () -> Void
    @Binding var showingReplay: Bool
    let replayAvailable: Bool
    @Binding var visible: Bool
    @State private var autoHideTask: Task<Void, Never>?
    @State private var isScrubbing: Bool = false
    @State private var wasPlayingBeforeScrub: Bool = false
    @State private var recencyText: String = ""
    @State private var recencyTimer: Timer?

    private static let speedOptions: [Float] = [0.25, 0.5, 1.0]

    var body: some View {
        ZStack {
            // Invisible tap target to toggle bottom controls
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        visible.toggle()
                    }
                    if visible {
                        resetAutoHide()
                    }
                }

            // PiP in top-right (during replay or initial black screen)
            if showingReplay || !replayAvailable {
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            // PiP - camera or video depending on mode
                            pipView
                                .onTapGesture {
                                    if replayAvailable {
                                        showingReplay = false
                                    }
                                }

                            // Import button below PiP
                            importButton
                        }
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }

            // REPLAY button in top-right (when viewing live full screen)
            if !showingReplay && replayAvailable {
                VStack {
                    HStack {
                        Spacer()
                        replayButton
                            .padding(.top, 16)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
            }

            // Always visible: recency label top-left (during replay)
            if showingReplay && !recencyText.isEmpty {
                VStack {
                    HStack {
                        Text(recencyText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.2))
                            )
                            .padding(.top, 16)
                            .padding(.leading, 16)
                        Spacer()
                    }
                    Spacer()
                }
            }

            // Toggled by tap: bottom playback controls
            if visible && showingReplay {
                bottomControls
                    .transition(.opacity)
            }
        }
        .onAppear {
            startRecencyTimer()
        }
        .onDisappear {
            stopRecencyTimer()
        }
    }

    private var bottomControls: some View {
        VStack {
            Spacer()

            VStack(spacing: 12) {
                scrubBar

                HStack {
                    // Left group: step-back, play/pause, step-fwd
                    HStack(spacing: 20) {
                        Button {
                            replayManager.stepBackward()
                            resetAutoHide()
                        } label: {
                            Image(systemName: "backward.frame.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }

                        Button {
                            replayManager.togglePlayPause()
                            resetAutoHide()
                        } label: {
                            Image(systemName: replayManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                        }

                        Button {
                            replayManager.stepForward()
                            resetAutoHide()
                        } label: {
                            Image(systemName: "forward.frame.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                    }

                    Spacer()

                    // Right: speed dropdown
                    speedMenu
                }
                .padding(.horizontal, 24)
            }
            .padding(.vertical, 16)
            .padding(.bottom, 8)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    // MARK: - Scrub Bar

    private var scrubBar: some View {
        GeometryReader { geo in
            let width = geo.size.width - 48 // horizontal padding
            let progress = replayManager.clipDuration > 0
                ? replayManager.currentTime / replayManager.clipDuration
                : 0

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)

                // Fill
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, width * progress), height: 4)

                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .offset(x: max(0, width * progress) - 8)
            }
            .padding(.horizontal, 24)
            .frame(height: 40)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isScrubbing {
                            isScrubbing = true
                            wasPlayingBeforeScrub = replayManager.isPlaying
                            replayManager.pause()
                        }
                        let fraction = max(0, min(1, (value.location.x - 24) / width))
                        replayManager.seek(to: fraction)
                        resetAutoHide()
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        if wasPlayingBeforeScrub {
                            replayManager.resume()
                        }
                        resetAutoHide()
                    }
            )
        }
        .frame(height: 40)
    }

    // MARK: - Speed Menu

    private var speedMenu: some View {
        Menu {
            ForEach(Self.speedOptions, id: \.self) { rate in
                Button {
                    replayManager.setRate(rate)
                    resetAutoHide()
                } label: {
                    HStack {
                        Text(speedLabel(rate))
                        if replayManager.currentRate == rate {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(speedLabel(replayManager.currentRate))
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                )
        }
    }

    // MARK: - PiP

    @ViewBuilder
    private var pipView: some View {
        Group {
            if inputMode == .camera {
                CameraPiPView(cameraManager: cameraManager)
            } else if let videoProcessor = videoProcessor {
                VideoPiPView(videoProcessor: videoProcessor)
            }
        }
        .frame(width: 160, height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.3), lineWidth: 2)
        )
        .shadow(radius: 4)
    }

    // MARK: - Import Button

    private var importButton: some View {
        Button(action: onImportTapped) {
            Image(systemName: inputMode == .camera ? "folder.badge.plus" : "xmark.circle.fill")
                .font(.title2)
                .foregroundColor(.white)
                .padding(12)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
    }

    // MARK: - Replay Button

    private var replayButton: some View {
        Button {
            showingReplay = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 14))
                Text("REPLAY")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.2))
            )
        }
    }

    // MARK: - Recency

    private func updateRecencyText() {
        guard let capturedAt = replayManager.clipCapturedAt else {
            recencyText = ""
            return
        }
        let elapsed = Date().timeIntervalSince(capturedAt)
        if elapsed < 30 {
            let seconds = Int(elapsed) + 1
            recencyText = "\(seconds)s ago"
        } else if elapsed < 60 {
            recencyText = "< 1m ago"
        } else if elapsed < 120 {
            recencyText = "< 2m ago"
        } else {
            recencyText = "> 2m ago"
        }
    }

    private func startRecencyTimer() {
        updateRecencyText()
        recencyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            DispatchQueue.main.async {
                updateRecencyText()
            }
        }
    }

    private func stopRecencyTimer() {
        recencyTimer?.invalidate()
        recencyTimer = nil
    }

    // MARK: - Helpers

    private func speedLabel(_ rate: Float) -> String {
        if rate == 0.25 { return "0.25x" }
        if rate == 0.5 { return "0.5x" }
        return "1x"
    }

    private func resetAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.2)) {
                    visible = false
                }
            }
        }
    }
}
