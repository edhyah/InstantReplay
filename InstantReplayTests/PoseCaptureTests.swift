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

    private func captureVideoPoses(videoName: String) throws {
        try XCTSkipIf(isSimulator, "Vision ML pose estimation unavailable on Simulator - run on real device")

        let testBundle = Bundle(for: Self.self)
        let videoExtensions = ["mov", "MOV", "mp4", "m4v"]

        var videoURL: URL?
        for ext in videoExtensions {
            if let url = testBundle.url(forResource: videoName, withExtension: ext) {
                videoURL = url
                break
            }
        }

        guard let videoURL = videoURL else {
            XCTFail("Video not found: \(videoName)")
            return
        }

        let outputDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outputURL = outputDir.appendingPathComponent("\(videoName).poses.json")

        print("Capturing poses from: \(videoURL.lastPathComponent)")

        let writer = PoseCaptureWriter(videoURL: videoURL, outputURL: outputURL)
        try writer.capture()

        print("Wrote poses to: \(outputURL.path)")

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

    func testCapture_IMG_1118() throws {
        try captureVideoPoses(videoName: "IMG_1118")
    }

    func testCapture_IMG_1940() throws {
        try captureVideoPoses(videoName: "IMG_1940")
    }

    func testCapture_IMG_1988() throws {
        try captureVideoPoses(videoName: "IMG_1988")
    }

    func testCapture_IMG_4584() throws {
        try captureVideoPoses(videoName: "IMG_4584")
    }

    func testCapture_IMG_4927() throws {
        try captureVideoPoses(videoName: "IMG_4927")
    }
}
