import XCTest

final class ReplayDetectionTests: XCTestCase {
    func testReplayAllCapturedPoses() throws {
        // Use #file-based path to find Resources directory
        let testFileURL = URL(fileURLWithPath: #file)
        let resourcesDir = testFileURL.deletingLastPathComponent().appendingPathComponent("Resources")

        guard FileManager.default.fileExists(atPath: resourcesDir.path) else {
            XCTFail("Resources directory not found at \(resourcesDir.path)")
            return
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: resourcesDir,
            includingPropertiesForKeys: nil
        )

        let poseURLs = contents.filter { $0.lastPathComponent.hasSuffix(".poses.json") }

        guard !poseURLs.isEmpty else {
            try XCTSkipIf(true, """
                No .poses.json files found in Resources directory.
                Copy pose files from InstantReplayTests/Resources/ to InstantReplayMacTests/Resources/
                """)
            return
        }

        print("DEBUG: Found \(poseURLs.count) pose files")
        let runner = ReplayDetectionRunner()

        for poseURL in poseURLs {
            print("DEBUG: Loading poses from \(poseURL.lastPathComponent)")
            let reader = try PoseReplayReader(url: poseURL)
            print("DEBUG: Loaded \(reader.frameCount) frames")

            // Try to find matching ground truth file
            let baseName = poseURL.lastPathComponent.replacingOccurrences(of: ".poses.json", with: "")
            let groundTruthURL = resourcesDir.appendingPathComponent("\(baseName).json")

            var groundTruth: GroundTruth?
            if FileManager.default.fileExists(atPath: groundTruthURL.path) {
                let truthData = try Data(contentsOf: groundTruthURL)
                groundTruth = try JSONDecoder().decode(GroundTruth.self, from: truthData)
            }

            let result = runner.run(reader: reader, groundTruth: groundTruth)
            let json = runner.outputJSON(result)

            // Output JSON in a format that can be parsed by CLI
            print("DETECTION_RESULT_BEGIN")
            print(json)
            print("DETECTION_RESULT_END")

            if let truth = groundTruth {
                // Assert test passes when ground truth is provided
                XCTAssertTrue(
                    result.passed,
                    "Detection results for \(result.video) did not match ground truth. " +
                    "Check JSON output for details."
                )

                // Detailed assertions for better error messages
                XCTAssertEqual(
                    result.detected.approachStarts.count,
                    truth.approaches.count,
                    "\(result.video): approachStart count mismatch"
                )
                XCTAssertEqual(
                    result.detected.takeoffs.count,
                    truth.approaches.count,
                    "\(result.video): takeoff count mismatch"
                )
                XCTAssertEqual(
                    result.detected.peaks.count,
                    truth.approaches.count,
                    "\(result.video): peak count mismatch"
                )
                XCTAssertEqual(
                    result.detected.landings.count,
                    truth.approaches.count,
                    "\(result.video): landing count mismatch"
                )
            }
        }
    }
}
