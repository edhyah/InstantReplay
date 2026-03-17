import XCTest
@testable import InstantReplay

final class PoseCaptureTests: XCTestCase {
    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    func testCaptureTestVideoPoses() throws {
        // Vision ML doesn't work on iOS Simulator - this test must run on a real device
        try XCTSkipIf(isSimulator, "Vision ML pose estimation unavailable on Simulator - run on real device")

        // Find test videos in the test bundle or Documents directory
        let testBundle = Bundle(for: Self.self)
        let videoExtensions = ["mov", "mp4", "m4v"]

        // Look for videos in the test bundle first
        var videoURLs: [URL] = []
        for ext in videoExtensions {
            videoURLs += testBundle.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? []
        }

        // Also check app's Documents directory for videos placed there
        if let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: documentsDir,
                includingPropertiesForKeys: nil
            ) {
                for ext in videoExtensions {
                    videoURLs += contents.filter { $0.pathExtension.lowercased() == ext }
                }
            }
        }

        guard !videoURLs.isEmpty else {
            XCTFail("No test videos found. Place .mov/.mp4 files in test bundle or app Documents directory.")
            return
        }

        let outputDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        for videoURL in videoURLs {
            let videoName = videoURL.deletingPathExtension().lastPathComponent
            let outputURL = outputDir.appendingPathComponent("\(videoName).poses.json")

            print("Capturing poses from: \(videoURL.lastPathComponent)")

            let writer = PoseCaptureWriter(videoURL: videoURL, outputURL: outputURL)
            try writer.capture()

            print("Wrote poses to: \(outputURL.path)")

            // Verify the output file exists and is valid JSON
            XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

            let data = try Data(contentsOf: outputURL)
            let capturedData = try JSONDecoder().decode(CapturedPoseData.self, from: data)

            print("  Video: \(capturedData.videoInfo.filename)")
            print("  Duration: \(String(format: "%.2f", capturedData.videoInfo.duration))s")
            print("  Frames captured: \(capturedData.frames.count)")

            let observationCounts = capturedData.frames.map { $0.observations.count }
            let avgObservations = observationCounts.isEmpty ? 0 : Double(observationCounts.reduce(0, +)) / Double(observationCounts.count)
            print("  Avg observations per frame: \(String(format: "%.1f", avgObservations))")

            XCTAssertGreaterThan(capturedData.frames.count, 0, "Should have captured at least one frame")
        }

        print("\n=== Pose capture complete ===")
        print("Copy .poses.json files from device Documents to InstantReplayTests/Resources/")
        print("Via Finder: Window > Devices and Simulators > select device > InstantReplay > download Documents")
    }
}
