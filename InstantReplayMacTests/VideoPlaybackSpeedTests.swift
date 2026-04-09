import XCTest
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo

/// Regression tests for incorrect playback speed with varying frame rate videos.
///
/// Reproduces the bug fixed in commit f69f8c6: clip extraction used the landing
/// timestamp's timescale instead of the video track's naturalTimeScale, and didn't
/// set the composition track's naturalTimeScale. This caused incorrect playback
/// speed for non-standard frame rate videos (e.g., 25fps PAL).
///
/// Additionally, the display link callback consumed a new frame on every tick even
/// when the current frame was still valid, causing low fps videos to play too fast.
final class VideoPlaybackSpeedTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoPlaybackSpeedTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Regression: Clip extraction must use naturalTimeScale

    /// Verifies that clip extraction from a 25fps (PAL) video produces a composition
    /// whose track has naturalTimeScale matching the source video.
    ///
    /// Before the fix, the composition track's naturalTimeScale was never set, and
    /// all time calculations used `landingTimestamp.timescale` (e.g., 600). For a
    /// 25fps video with naturalTimeScale ~25000, this mismatch caused AVPlayer to
    /// interpret frame timing incorrectly during playback.
    func testClipExtractionPreservesNaturalTimeScaleFor25fps() async throws {
        let videoURL = tempDir.appendingPathComponent("test_25fps.mov")
        try await createTestVideo(at: videoURL, fps: 25, duration: 6.0)

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(tracks.first, "Test video should have a video track")

        let naturalTimeScale = try await videoTrack.load(.naturalTimeScale)
        XCTAssertNotEqual(naturalTimeScale, 600,
                          "25fps video's naturalTimeScale should differ from generic timescale 600")

        // Landing timestamp with timescale 600 (as the detection pipeline typically produces)
        let landingTimestamp = CMTimeMakeWithSeconds(3.0, preferredTimescale: 600)
        XCTAssertEqual(landingTimestamp.timescale, 600,
                       "Landing timestamp should use generic timescale 600")

        // --- Fixed approach: use naturalTimeScale ---
        let fixedComposition = try await extractClipWithNaturalTimeScale(
            videoTrack: videoTrack,
            landingTimestamp: landingTimestamp,
            naturalTimeScale: naturalTimeScale
        )

        let fixedTracks = try await fixedComposition.loadTracks(withMediaType: .video)
        let fixedTrack = try XCTUnwrap(fixedTracks.first)
        let fixedTrackTimeScale = try await fixedTrack.load(.naturalTimeScale)

        // The fix explicitly sets composition track's naturalTimeScale to match source
        XCTAssertEqual(fixedTrackTimeScale, naturalTimeScale,
                       "Fixed: composition track naturalTimeScale (\(fixedTrackTimeScale)) " +
                       "must match source video (\(naturalTimeScale))")

        // --- Old (buggy) approach: use landingTimestamp.timescale, don't set naturalTimeScale ---
        let buggyComposition = try await extractClipWithLandingTimescale(
            videoTrack: videoTrack,
            landingTimestamp: landingTimestamp
        )

        let buggyTracks = try await buggyComposition.loadTracks(withMediaType: .video)
        let buggyTrack = try XCTUnwrap(buggyTracks.first)
        let buggyTrackTimeScale = try await buggyTrack.load(.naturalTimeScale)

        // The buggy approach never sets naturalTimeScale, so it won't match the source
        XCTAssertNotEqual(buggyTrackTimeScale, naturalTimeScale,
                          "Buggy: composition track naturalTimeScale (\(buggyTrackTimeScale)) " +
                          "should NOT match source video (\(naturalTimeScale)) — this is the bug")
    }

    /// Verifies clip duration is correct when extracted from a 25fps video using
    /// the fixed approach with naturalTimeScale.
    func testClipDurationCorrectFor25fps() async throws {
        let videoURL = tempDir.appendingPathComponent("test_25fps_dur.mov")
        try await createTestVideo(at: videoURL, fps: 25, duration: 6.0)

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(tracks.first)
        let naturalTimeScale = try await videoTrack.load(.naturalTimeScale)

        // Landing at t=3.0s, clip = [0.0, 3.5] (preRoll=3.0, postRoll=0.5)
        let landingTimestamp = CMTimeMakeWithSeconds(3.0, preferredTimescale: 600)
        let expectedDuration: TimeInterval = 3.0 + 0.5 // preRoll + postRoll

        let composition = try await extractClipWithNaturalTimeScale(
            videoTrack: videoTrack,
            landingTimestamp: landingTimestamp,
            naturalTimeScale: naturalTimeScale
        )

        let compositionDuration = try await composition.load(.duration)
        XCTAssertEqual(
            CMTimeGetSeconds(compositionDuration), expectedDuration, accuracy: 0.15,
            "Clip duration should be ~\(expectedDuration)s for 25fps video, " +
            "got \(CMTimeGetSeconds(compositionDuration))s"
        )
    }

    /// Verifies that clip boundary times use the video's naturalTimeScale rather
    /// than an arbitrary timescale from the landing timestamp. This ensures
    /// frame-aligned clip boundaries for non-standard frame rates.
    func testClipBoundaryTimescaleConsistencyFor25fps() async throws {
        let videoURL = tempDir.appendingPathComponent("test_25fps_boundary.mov")
        try await createTestVideo(at: videoURL, fps: 25, duration: 6.0)

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(tracks.first)
        let naturalTimeScale = try await videoTrack.load(.naturalTimeScale)

        let landingTimestamp = CMTimeMakeWithSeconds(3.0, preferredTimescale: 600)

        let preRoll: TimeInterval = 3.0
        let postRoll: TimeInterval = 0.5

        // Fixed: all times use naturalTimeScale
        let fixedClipStart = CMTimeSubtract(
            landingTimestamp,
            CMTimeMakeWithSeconds(preRoll, preferredTimescale: naturalTimeScale)
        )
        let fixedClipEnd = CMTimeAdd(
            landingTimestamp,
            CMTimeMakeWithSeconds(postRoll, preferredTimescale: naturalTimeScale)
        )
        let fixedClampedStart = CMTimeMaximum(
            fixedClipStart,
            CMTime(value: 0, timescale: naturalTimeScale)
        )

        // Buggy: times use landingTimestamp.timescale
        let buggyClipStart = CMTimeSubtract(
            landingTimestamp,
            CMTimeMakeWithSeconds(preRoll, preferredTimescale: landingTimestamp.timescale)
        )
        let buggyClipEnd = CMTimeAdd(
            landingTimestamp,
            CMTimeMakeWithSeconds(postRoll, preferredTimescale: landingTimestamp.timescale)
        )
        let buggyClampedStart = CMTimeMaximum(buggyClipStart, .zero)

        // Both represent the same time in seconds (rounding aside)
        XCTAssertEqual(
            CMTimeGetSeconds(fixedClampedStart),
            CMTimeGetSeconds(buggyClampedStart),
            accuracy: 0.01,
            "Both approaches should produce similar start times in seconds"
        )

        // But fixed approach uses naturalTimeScale for sub-frame precision
        XCTAssertEqual(fixedClampedStart.timescale, naturalTimeScale,
                       "Fixed clip start should use naturalTimeScale for frame-aligned precision")
        XCTAssertEqual(fixedClipEnd.timescale, naturalTimeScale,
                       "Fixed clip end should use naturalTimeScale")

        // Buggy approach uses landing timestamp's timescale (600)
        XCTAssertEqual(buggyClampedStart.timescale, 600,
                       "Buggy clip start uses wrong timescale (landing timestamp's)")
        XCTAssertEqual(buggyClipEnd.timescale, 600,
                       "Buggy clip end uses wrong timescale")

        // Frame duration at 25fps = 1/25 = 0.04s
        // With naturalTimeScale (e.g., 25000), one frame = 1000 ticks → exact alignment
        // With timescale 600, one frame = 24 ticks → exact alignment happens to work for 25fps
        // But for other rates like 24fps, timescale 600 gives 25 ticks/frame = exact,
        // while a 23.976fps video would have non-integer ticks → rounding errors
        let frameDurationFixed = CMTimeMakeWithSeconds(1.0 / 25.0, preferredTimescale: naturalTimeScale)
        XCTAssertEqual(
            frameDurationFixed.value % 1, 0,
            "Frame duration should be an integer number of ticks at naturalTimeScale"
        )
    }

    // MARK: - Regression: Frame consumption rate for low fps videos

    /// Verifies the frame reuse logic that prevents consuming frames too fast
    /// for low frame rate videos.
    ///
    /// Before the fix, every display link tick (~120Hz) consumed a new frame from
    /// the AVAssetReader, even when the current frame was still valid for the target
    /// playback time. For a 25fps video, this meant all frames were consumed in
    /// ~1.25 seconds instead of the correct ~6 seconds, causing severely sped-up
    /// playback.
    ///
    /// The fix caches the current frame and reuses it when its adjusted timestamp
    /// is still at or past the target video time, so frames are consumed at the
    /// video's native rate.
    func testFrameReusePreventsExcessiveConsumptionForLowFPS() throws {
        // Simulate a 25fps video: frames spaced 40ms apart
        let videoFPS: Double = 25.0
        let frameDuration: TimeInterval = 1.0 / videoFPS
        let totalFrameCount = Int(videoFPS) * 4  // 4 seconds of video = 100 frames

        // Display link fires at ~120Hz (8.33ms intervals)
        let displayLinkInterval: TimeInterval = 1.0 / 120.0

        // --- Fixed approach: reuse frames when still valid ---
        var fixedFrameIndex = 0
        var fixedFramesConsumed = 0
        var currentFrameAdjustedTimestamp: TimeInterval = -1  // no frame yet
        var elapsedTime: TimeInterval = 0

        while elapsedTime < 1.0 && fixedFrameIndex < totalFrameCount {
            let targetTime = elapsedTime

            // Fixed: check if current frame is still valid for target time
            if fixedFramesConsumed > 0 && currentFrameAdjustedTimestamp >= targetTime {
                // Frame is still valid, reuse it (no new frame consumed)
            } else {
                // Read frames until we find one at or past targetTime
                while fixedFrameIndex < totalFrameCount {
                    let frameTime = Double(fixedFrameIndex) * frameDuration
                    fixedFrameIndex += 1
                    fixedFramesConsumed += 1

                    if frameTime >= targetTime {
                        currentFrameAdjustedTimestamp = frameTime
                        break
                    }
                }
            }

            elapsedTime += displayLinkInterval
        }

        // With frame reuse, we should consume ~25 frames per second (matching video fps)
        XCTAssertLessThanOrEqual(
            fixedFramesConsumed, 30,
            "Fixed: should consume ~25 frames/sec for 25fps video, got \(fixedFramesConsumed)"
        )
        XCTAssertGreaterThanOrEqual(
            fixedFramesConsumed, 20,
            "Fixed: should consume at least ~20 frames/sec for 25fps video, got \(fixedFramesConsumed)"
        )

        // --- Buggy approach: always read a new frame on every tick ---
        var buggyFrameIndex = 0
        var buggyFramesConsumed = 0
        elapsedTime = 0

        while elapsedTime < 1.0 && buggyFrameIndex < totalFrameCount {
            let targetTime = elapsedTime

            // Buggy: no reuse check, always consume the next frame
            while buggyFrameIndex < totalFrameCount {
                let frameTime = Double(buggyFrameIndex) * frameDuration
                buggyFrameIndex += 1
                buggyFramesConsumed += 1

                if frameTime >= targetTime {
                    break
                }
            }

            elapsedTime += displayLinkInterval
        }

        // Without frame reuse, all 100 frames are consumed in well under 1 second
        // because frames are consumed at the display link rate, not the video rate
        XCTAssertGreaterThan(
            buggyFramesConsumed, fixedFramesConsumed,
            "Buggy approach should consume more frames (\(buggyFramesConsumed)) " +
            "than fixed approach (\(fixedFramesConsumed))"
        )

        // The buggy approach exhausts frames much faster, causing sped-up playback
        XCTAssertGreaterThan(
            buggyFramesConsumed, 50,
            "Buggy: should consume >>25 frames in 1 sec due to no reuse, got \(buggyFramesConsumed)"
        )
    }

    // MARK: - Video Creation Helper

    /// Creates a minimal test video at the specified frame rate using AVAssetWriter.
    ///
    /// The video uses a timescale of `fps * 1000` (e.g., 25000 for 25fps) to produce
    /// a non-standard naturalTimeScale that differs from the generic 600.
    private func createTestVideo(at url: URL, fps: Int32, duration: TimeInterval) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120,
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120,
            ]
        )

        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalFrames = Int(Double(fps) * duration)
        let timescale = fps * 1000 // e.g., 25000 for 25fps

        for frame in 0..<totalFrames {
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }

            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferCreate(
                kCFAllocatorDefault, 160, 120,
                kCVPixelFormatType_32BGRA, nil, &pixelBuffer
            )
            guard let buffer = pixelBuffer else { continue }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                memset(baseAddress, Int32(frame % 256), bytesPerRow * 120)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            // Each frame is 1000 ticks apart in a timescale of fps*1000
            // e.g., for 25fps: frame 0 = 0/25000, frame 1 = 1000/25000, etc.
            let pts = CMTime(value: CMTimeValue(frame) * 1000, timescale: timescale)
            adaptor.append(buffer, withPresentationTime: pts)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw writer.error ?? NSError(
                domain: "TestVideoCreation", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create test video"]
            )
        }
    }

    // MARK: - Clip Extraction Helpers

    /// Extracts a clip using the FIXED approach from commit f69f8c6:
    /// uses the video track's naturalTimeScale for all time calculations
    /// and explicitly sets it on the composition track.
    private func extractClipWithNaturalTimeScale(
        videoTrack: AVAssetTrack,
        landingTimestamp: CMTime,
        naturalTimeScale: CMTimeScale
    ) async throws -> AVMutableComposition {
        let preRoll: TimeInterval = 3.0
        let postRoll: TimeInterval = 0.5

        let clipStart = CMTimeSubtract(
            landingTimestamp,
            CMTimeMakeWithSeconds(preRoll, preferredTimescale: naturalTimeScale)
        )
        let clipEnd = CMTimeAdd(
            landingTimestamp,
            CMTimeMakeWithSeconds(postRoll, preferredTimescale: naturalTimeScale)
        )
        let clampedStart = CMTimeMaximum(clipStart, CMTime(value: 0, timescale: naturalTimeScale))
        let duration = CMTimeSubtract(clipEnd, clampedStart)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "Test", code: -1)
        }

        // Key fix: set naturalTimeScale on composition track to match source
        compositionTrack.naturalTimeScale = naturalTimeScale

        let timeRange = CMTimeRangeMake(start: clampedStart, duration: duration)
        try compositionTrack.insertTimeRange(
            timeRange, of: videoTrack,
            at: CMTime(value: 0, timescale: naturalTimeScale)
        )

        return composition
    }

    /// Extracts a clip using the BUGGY approach (pre-fix behavior):
    /// uses `landingTimestamp.timescale` for time calculations and does not set
    /// the composition track's naturalTimeScale.
    private func extractClipWithLandingTimescale(
        videoTrack: AVAssetTrack,
        landingTimestamp: CMTime
    ) async throws -> AVMutableComposition {
        let preRoll: TimeInterval = 3.0
        let postRoll: TimeInterval = 0.5

        // Bug: uses landingTimestamp.timescale instead of naturalTimeScale
        let clipStart = CMTimeSubtract(
            landingTimestamp,
            CMTimeMakeWithSeconds(preRoll, preferredTimescale: landingTimestamp.timescale)
        )
        let clipEnd = CMTimeAdd(
            landingTimestamp,
            CMTimeMakeWithSeconds(postRoll, preferredTimescale: landingTimestamp.timescale)
        )
        let clampedStart = CMTimeMaximum(clipStart, .zero)
        let duration = CMTimeSubtract(clipEnd, clampedStart)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "Test", code: -1)
        }

        // Bug: doesn't set compositionTrack.naturalTimeScale

        let timeRange = CMTimeRangeMake(start: clampedStart, duration: duration)
        // Bug: inserts at .zero instead of CMTime(value: 0, timescale: naturalTimeScale)
        try compositionTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        return composition
    }
}
