import XCTest

final class ThresholdTuningTests: XCTestCase {
    func testGridSearchThresholds() throws {
        // Load all pose files with ground truth
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
            try XCTSkipIf(true, "No .poses.json files found in Resources directory.")
            return
        }

        // Load videos with ground truth only
        var testVideos: [TestVideo] = []
        for poseURL in poseURLs {
            let reader = try PoseReplayReader(url: poseURL)
            let baseName = poseURL.lastPathComponent.replacingOccurrences(of: ".poses.json", with: "")
            let groundTruthURL = resourcesDir.appendingPathComponent("\(baseName).json")

            guard FileManager.default.fileExists(atPath: groundTruthURL.path) else {
                print("Skipping \(baseName) - no ground truth file")
                continue
            }

            let truthData = try Data(contentsOf: groundTruthURL)
            let groundTruth = try JSONDecoder().decode(GroundTruth.self, from: truthData)
            testVideos.append(TestVideo(reader: reader, groundTruth: groundTruth))
            print("Loaded: \(baseName) with \(groundTruth.approaches.count) approaches")
        }

        guard !testVideos.isEmpty else {
            try XCTSkipIf(true, "No test videos with ground truth found.")
            return
        }

        print("\n=== THRESHOLD TUNING ===")
        print("Videos loaded: \(testVideos.count)")
        let totalApproaches = testVideos.reduce(0) { $0 + $1.groundTruth.approaches.count }
        print("Total approaches: \(totalApproaches)")

        // Define search ranges for key velocity thresholds
        let config = GridSearchConfig(
            approachHorizontalVelocity: ThresholdRange(name: "approachHorizontalVelocity", min: 0.12, max: 0.28, step: 0.04),
            ascendingVerticalVelocity: ThresholdRange(name: "ascendingVerticalVelocity", min: -0.35, max: -0.15, step: 0.05),
            descendingVerticalVelocity: ThresholdRange(name: "descendingVerticalVelocity", min: 0.05, max: 0.20, step: 0.03),
            landingVerticalMagnitude: ThresholdRange(name: "landingVerticalMagnitude", min: 0.04, max: 0.15, step: 0.02)
        )

        print("Search space: \(config.totalCombinations) combinations")
        print("Searching...\n")

        let session = TuningSession(videos: testVideos)
        let searcher = GridSearcher(session: session, config: config)

        let startTime = Date()
        let results = searcher.search { evaluated, total in
            if evaluated % 100 == 0 || evaluated == total {
                print("Progress: \(evaluated)/\(total)")
            }
        }
        let elapsed = Date().timeIntervalSince(startTime)

        print("\n=== RESULTS ===")
        print("Search completed in \(String(format: "%.1f", elapsed)) seconds")

        // Show current defaults result
        let defaultThresholds = StateMachineThresholds()
        let defaultResult = session.evaluate(thresholds: defaultThresholds)
        print("\n--- CURRENT DEFAULTS ---")
        print("Pass Rate: \(String(format: "%.0f%%", defaultResult.passRate * 100))")
        print("Total Error: \(String(format: "%.3fs", defaultResult.totalError))")
        print("Max Error: \(String(format: "%.3fs", defaultResult.maxError))")

        // Show top 10 results
        print("\n--- TOP 10 CONFIGURATIONS ---")
        for (index, result) in results.prefix(10).enumerated() {
            print(searcher.formatResult(result, rank: index + 1))
            print()
        }

        // Show recommended code snippet for best result
        if let best = results.first {
            print("--- RECOMMENDED CODE ---")
            print(searcher.generateCodeSnippet(best))
            print()

            // Compare improvement
            let improvement = defaultResult.totalError - best.totalError
            if improvement > 0 {
                print("Improvement: \(String(format: "%.3fs", improvement)) total error reduction")
            }
        }

        // Filter to only 100% pass rate configs
        let passingConfigs = results.filter { $0.passRate == 1.0 }
        print("\nConfigurations with 100% pass rate: \(passingConfigs.count)/\(results.count)")

        // Test passes if we found at least one configuration that works
        XCTAssertFalse(results.isEmpty, "Grid search should produce results")
    }
}
