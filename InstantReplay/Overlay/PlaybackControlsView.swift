import Combine
import SwiftUI

struct PlaybackControlsView: View {
    let replayManager: ReplayManager
    let comparisonReplayManager: ComparisonReplayManager?
    let cameraManager: CameraManager
    let inputMode: InputMode
    let videoProcessor: VideoFileProcessor?
    let onImportTapped: () -> Void
    let onCompareTapped: () -> Void
    @Binding var showingReplay: Bool
    let replayAvailable: Bool
    let isComparisonReplay: Bool
    let comparisonVideoLoaded: Bool
    @Binding var visible: Bool
    @State private var autoHideTask: Task<Void, Never>?
    @State private var isScrubbing: Bool = false
    @State private var wasPlayingBeforeScrub: Bool = false
    @State private var recencyText: String = ""

    private static let speedOptions: [Float] = [0.25, 0.5, 1.0]

    var body: some View {
        ZStack {
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

                            topToolButtons
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
                        HStack(spacing: 10) {
                            replayButton
                            topToolButtons
                        }
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
            updateRecencyText()
        }
        .onChange(of: visible) { _, isVisible in
            if isVisible {
                resetAutoHide()
            }
        }
        .onChange(of: isComparisonReplay) {
            updateRecencyText()
        }
        .onChange(of: activeClipCapturedAt) {
            updateRecencyText()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateRecencyText()
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
                            stepBackward()
                            resetAutoHide()
                        } label: {
                            Image(systemName: "backward.frame.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }

                        Button {
                            togglePlayPause()
                            resetAutoHide()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                        }

                        Button {
                            stepForward()
                            resetAutoHide()
                        } label: {
                            Image(systemName: "forward.frame.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                    }

                    Spacer()

                    if isComparisonReplay {
                        nudgeControls
                    }

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
            let progress = clipDuration > 0
                ? currentTime / clipDuration
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
                            wasPlayingBeforeScrub = isPlaying
                            pause()
                        }
                        let fraction = max(0, min(1, (value.location.x - 24) / width))
                        seek(to: fraction)
                        resetAutoHide()
                    }
                    .onEnded { _ in
                        isScrubbing = false
                        if wasPlayingBeforeScrub {
                            resume()
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
                    setRate(rate)
                    resetAutoHide()
                } label: {
                    HStack {
                        Text(speedLabel(rate))
                        if currentRate == rate {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(speedLabel(currentRate))
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

    // MARK: - Camera Switch Button

    private var topToolButtons: some View {
        HStack(spacing: 10) {
            if inputMode == .camera {
                cameraSwitchButton
            }

            importButton
            compareButton
        }
    }

    private var cameraSwitchButton: some View {
        Button {
            cameraManager.switchCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title2)
                .foregroundColor(.white)
                .padding(12)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
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

    private var compareButton: some View {
        Button(action: onCompareTapped) {
            Image(systemName: isComparisonReplay ? "rectangle" : "rectangle.split.2x1")
                .font(.title2)
                .foregroundColor(.white)
                .padding(12)
                .background(comparisonVideoLoaded ? Color.white.opacity(0.28) : Color.black.opacity(0.6))
                .clipShape(Circle())
        }
    }

    private var nudgeControls: some View {
        HStack(spacing: 12) {
            Button {
                comparisonReplayManager?.nudgeReference(by: -1.0 / 30.0)
                resetAutoHide()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }

            Button {
                comparisonReplayManager?.resetReferenceOffset()
                resetAutoHide()
            } label: {
                Text(String(format: "%+.2fs", comparisonReplayManager?.referenceOffset ?? 0))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 56)
            }

            Button {
                comparisonReplayManager?.nudgeReference(by: 1.0 / 30.0)
                resetAutoHide()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.2))
        )
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
        guard let capturedAt = activeClipCapturedAt else {
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

    // MARK: - Helpers

    private func speedLabel(_ rate: Float) -> String {
        if rate == 0.25 { return "0.25x" }
        if rate == 0.5 { return "0.5x" }
        return "1x"
    }

    private var activeComparisonManager: ComparisonReplayManager? {
        isComparisonReplay ? comparisonReplayManager : nil
    }

    private var clipDuration: Double {
        activeComparisonManager?.clipDuration ?? replayManager.clipDuration
    }

    private var currentTime: Double {
        activeComparisonManager?.currentTime ?? replayManager.currentTime
    }

    private var currentRate: Float {
        activeComparisonManager?.currentRate ?? replayManager.currentRate
    }

    private var isPlaying: Bool {
        activeComparisonManager?.isPlaying ?? replayManager.isPlaying
    }

    private var activeClipCapturedAt: Date? {
        activeComparisonManager?.clipCapturedAt ?? replayManager.clipCapturedAt
    }

    private func stepBackward() {
        if let activeComparisonManager {
            activeComparisonManager.stepBackward()
        } else {
            replayManager.stepBackward()
        }
    }

    private func stepForward() {
        if let activeComparisonManager {
            activeComparisonManager.stepForward()
        } else {
            replayManager.stepForward()
        }
    }

    private func togglePlayPause() {
        if let activeComparisonManager {
            activeComparisonManager.togglePlayPause()
        } else {
            replayManager.togglePlayPause()
        }
    }

    private func pause() {
        if let activeComparisonManager {
            activeComparisonManager.pause()
        } else {
            replayManager.pause()
        }
    }

    private func resume() {
        if let activeComparisonManager {
            activeComparisonManager.resume()
        } else {
            replayManager.resume()
        }
    }

    private func seek(to fraction: Double) {
        if let activeComparisonManager {
            activeComparisonManager.seek(to: fraction)
        } else {
            replayManager.seek(to: fraction)
        }
    }

    private func setRate(_ rate: Float) {
        if let activeComparisonManager {
            activeComparisonManager.setRate(rate)
        } else {
            replayManager.setRate(rate)
        }
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
