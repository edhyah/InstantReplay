import XCTest

final class StepDetectionTests: XCTestCase {
    private let stepTolerance: TimeInterval = 0.20  // ±0.20s (~3 frames at 15fps)
    private let plantToTakeoffTolerance: TimeInterval = 0.25  // 250ms

    private var resourcesDir: URL {
        let testFileURL = URL(fileURLWithPath: #file)
        return testFileURL.deletingLastPathComponent().appendingPathComponent("Resources")
    }

    private func loadTestData(for videoName: String) throws -> (reader: PoseReplayReader, groundTruth: GroundTruth) {
        let poseURL = resourcesDir.appendingPathComponent("\(videoName).poses.json")
        let groundTruthURL = resourcesDir.appendingPathComponent("\(videoName).json")

        guard FileManager.default.fileExists(atPath: poseURL.path) else {
            throw XCTSkip("Pose file not found: \(videoName).poses.json")
        }
        guard FileManager.default.fileExists(atPath: groundTruthURL.path) else {
            throw XCTSkip("Ground truth file not found: \(videoName).json")
        }

        let reader = try PoseReplayReader(url: poseURL)
        let truthData = try Data(contentsOf: groundTruthURL)
        let groundTruth = try JSONDecoder().decode(GroundTruth.self, from: truthData)

        return (reader, groundTruth)
    }

    private func runDetection(reader: PoseReplayReader, groundTruth: GroundTruth) -> ReplayDetectionResult {
        let runner = ReplayDetectionRunner()
        return runner.run(reader: reader, groundTruth: groundTruth)
    }

    private func getAllTestVideos() throws -> [(name: String, reader: PoseReplayReader, groundTruth: GroundTruth)] {
        guard FileManager.default.fileExists(atPath: resourcesDir.path) else {
            throw XCTSkip("Resources directory not found")
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: resourcesDir,
            includingPropertiesForKeys: nil
        )

        let poseURLs = contents.filter { $0.lastPathComponent.hasSuffix(".poses.json") }

        guard !poseURLs.isEmpty else {
            throw XCTSkip("No .poses.json files found in Resources directory")
        }

        var results: [(name: String, reader: PoseReplayReader, groundTruth: GroundTruth)] = []

        for poseURL in poseURLs {
            let baseName = poseURL.lastPathComponent.replacingOccurrences(of: ".poses.json", with: "")
            let groundTruthURL = resourcesDir.appendingPathComponent("\(baseName).json")

            guard FileManager.default.fileExists(atPath: groundTruthURL.path) else {
                continue  // Skip videos without ground truth
            }

            let reader = try PoseReplayReader(url: poseURL)
            let truthData = try Data(contentsOf: groundTruthURL)
            let groundTruth = try JSONDecoder().decode(GroundTruth.self, from: truthData)

            // Only include videos with step labels
            guard groundTruth.approaches.contains(where: { $0.steps != nil }) else {
                continue
            }

            results.append((baseName, reader, groundTruth))
        }

        guard !results.isEmpty else {
            throw XCTSkip("No videos with step labels found")
        }

        return results
    }

    // MARK: - Core Step Detection Tests

    func testStepsDetectedInCorrectOrder() throws {
        let testVideos = try getAllTestVideos()

        for (videoName, reader, groundTruth) in testVideos {
            let result = runDetection(reader: reader, groundTruth: groundTruth)

            for (approachIndex, stepSequence) in result.detected.steps.enumerated() {
                // Steps must be in chronological order: first < second < orientation < plant
                for i in 1..<stepSequence.count {
                    XCTAssertLessThan(
                        stepSequence[i - 1].timestamp,
                        stepSequence[i].timestamp,
                        "\(videoName) approach \(approachIndex): step \(stepSequence[i - 1].type.rawValue) " +
                        "(\(stepSequence[i - 1].timestamp)s) should come before " +
                        "\(stepSequence[i].type.rawValue) (\(stepSequence[i].timestamp)s)"
                    )
                }

                // Verify step type order
                if stepSequence.count == 4 {
                    XCTAssertEqual(stepSequence[0].type, .first, "\(videoName) approach \(approachIndex)")
                    XCTAssertEqual(stepSequence[1].type, .second, "\(videoName) approach \(approachIndex)")
                    XCTAssertEqual(stepSequence[2].type, .orientation, "\(videoName) approach \(approachIndex)")
                    XCTAssertEqual(stepSequence[3].type, .plant, "\(videoName) approach \(approachIndex)")
                }
            }
        }
    }

    func testStepSequenceCountMatchesApproachCount() throws {
        let testVideos = try getAllTestVideos()

        for (videoName, reader, groundTruth) in testVideos {
            let result = runDetection(reader: reader, groundTruth: groundTruth)

            let approachesWithSteps = groundTruth.approaches.filter { $0.steps != nil }.count

            XCTAssertEqual(
                result.detected.steps.count,
                approachesWithSteps,
                "\(videoName): Expected \(approachesWithSteps) step sequences but detected \(result.detected.steps.count)"
            )
        }
    }

    func testEachApproachHasFourSteps() throws {
        let testVideos = try getAllTestVideos()

        for (videoName, reader, groundTruth) in testVideos {
            let result = runDetection(reader: reader, groundTruth: groundTruth)

            for (approachIndex, stepSequence) in result.detected.steps.enumerated() {
                XCTAssertEqual(
                    stepSequence.count,
                    4,
                    "\(videoName) approach \(approachIndex): Expected 4 steps (first, second, orientation, plant) " +
                    "but detected \(stepSequence.count)"
                )
            }
        }
    }

    func testStepTimestampsWithinTolerance() throws {
        let testVideos = try getAllTestVideos()

        for (videoName, reader, groundTruth) in testVideos {
            let result = runDetection(reader: reader, groundTruth: groundTruth)

            for (approachIndex, stepComparisons) in result.errors.steps.enumerated() {
                for comparison in stepComparisons {
                    XCTAssertTrue(
                        comparison.withinTolerance,
                        "\(videoName) approach \(approachIndex) \(comparison.stepType): " +
                        "detected=\(comparison.detected ?? -1)s, expected=\(comparison.expected)s, " +
                        "delta=\(comparison.delta ?? -1)s (tolerance: \(stepTolerance)s)"
                    )
                }
            }
        }
    }

    func testFootIdentificationCorrect() throws {
        let testVideos = try getAllTestVideos()

        for (videoName, reader, groundTruth) in testVideos {
            let result = runDetection(reader: reader, groundTruth: groundTruth)

            for (approachIndex, stepComparisons) in result.errors.steps.enumerated() {
                for comparison in stepComparisons {
                    XCTAssertTrue(
                        comparison.footMatch,
                        "\(videoName) approach \(approachIndex) \(comparison.stepType): foot identification mismatch"
                    )
                }
            }
        }
    }

    func testStepsOccurBetweenApproachStartAndTakeoff() throws {
        let testVideos = try getAllTestVideos()

        for (videoName, reader, groundTruth) in testVideos {
            let result = runDetection(reader: reader, groundTruth: groundTruth)

            let approachesWithSteps = groundTruth.approaches.filter { $0.steps != nil }

            for (approachIndex, stepSequence) in result.detected.steps.enumerated() {
                guard approachIndex < approachesWithSteps.count else { continue }
                let approach = approachesWithSteps[approachIndex]

                for step in stepSequence {
                    XCTAssertGreaterThanOrEqual(
                        step.timestamp,
                        approach.approachStart,
                        "\(videoName) approach \(approachIndex) \(step.type.rawValue): " +
                        "step at \(step.timestamp)s occurs before approachStart at \(approach.approachStart)s"
                    )

                    XCTAssertLessThanOrEqual(
                        step.timestamp,
                        approach.takeoff,
                        "\(videoName) approach \(approachIndex) \(step.type.rawValue): " +
                        "step at \(step.timestamp)s occurs after takeoff at \(approach.takeoff)s"
                    )
                }
            }
        }
    }

    func testPlantStepCloseToTakeoff() throws {
        let testVideos = try getAllTestVideos()

        for (videoName, reader, groundTruth) in testVideos {
            let result = runDetection(reader: reader, groundTruth: groundTruth)

            let approachesWithSteps = groundTruth.approaches.filter { $0.steps != nil }

            for (approachIndex, stepSequence) in result.detected.steps.enumerated() {
                guard approachIndex < approachesWithSteps.count else { continue }
                let approach = approachesWithSteps[approachIndex]

                guard let plantStep = stepSequence.first(where: { $0.type == .plant }) else {
                    XCTFail("\(videoName) approach \(approachIndex): no plant step detected")
                    continue
                }

                let timeDiff = approach.takeoff - plantStep.timestamp

                XCTAssertLessThanOrEqual(
                    timeDiff,
                    plantToTakeoffTolerance,
                    "\(videoName) approach \(approachIndex): plant step at \(plantStep.timestamp)s " +
                    "is \(timeDiff)s before takeoff at \(approach.takeoff)s (max: \(plantToTakeoffTolerance)s)"
                )

                XCTAssertGreaterThanOrEqual(
                    timeDiff,
                    0,
                    "\(videoName) approach \(approachIndex): plant step at \(plantStep.timestamp)s " +
                    "occurs after takeoff at \(approach.takeoff)s"
                )
            }
        }
    }

    // MARK: - Per-Video Tests (for debugging individual videos)

    func testStepDetection_IMG_1118() throws {
        let (reader, groundTruth) = try loadTestData(for: "IMG_1118")
        let result = runDetection(reader: reader, groundTruth: groundTruth)

        // IMG_1118 has 2 approaches with step labels
        XCTAssertEqual(result.detected.steps.count, 2, "Expected 2 step sequences for IMG_1118")

        for (i, stepSequence) in result.detected.steps.enumerated() {
            XCTAssertEqual(stepSequence.count, 4, "Approach \(i) should have 4 steps")
        }
    }

    func testStepDetection_IMG_1940() throws {
        let (reader, groundTruth) = try loadTestData(for: "IMG_1940")
        let result = runDetection(reader: reader, groundTruth: groundTruth)

        // IMG_1940 has 1 approach with step labels
        XCTAssertEqual(result.detected.steps.count, 1, "Expected 1 step sequence for IMG_1940")

        for (i, stepSequence) in result.detected.steps.enumerated() {
            XCTAssertEqual(stepSequence.count, 4, "Approach \(i) should have 4 steps")
        }
    }

    func testStepDetection_IMG_1988() throws {
        let (reader, groundTruth) = try loadTestData(for: "IMG_1988")
        let result = runDetection(reader: reader, groundTruth: groundTruth)

        let approachesWithSteps = groundTruth.approaches.filter { $0.steps != nil }.count
        XCTAssertEqual(
            result.detected.steps.count,
            approachesWithSteps,
            "Expected \(approachesWithSteps) step sequences for IMG_1988"
        )

        for (i, stepSequence) in result.detected.steps.enumerated() {
            XCTAssertEqual(stepSequence.count, 4, "Approach \(i) should have 4 steps")
        }
    }

    func testStepDetection_IMG_4584() throws {
        let (reader, groundTruth) = try loadTestData(for: "IMG_4584")
        let result = runDetection(reader: reader, groundTruth: groundTruth)

        let approachesWithSteps = groundTruth.approaches.filter { $0.steps != nil }.count
        XCTAssertEqual(
            result.detected.steps.count,
            approachesWithSteps,
            "Expected \(approachesWithSteps) step sequences for IMG_4584"
        )

        for (i, stepSequence) in result.detected.steps.enumerated() {
            XCTAssertEqual(stepSequence.count, 4, "Approach \(i) should have 4 steps")
        }
    }

    func testStepDetection_IMG_4927() throws {
        let (reader, groundTruth) = try loadTestData(for: "IMG_4927")
        let result = runDetection(reader: reader, groundTruth: groundTruth)

        let approachesWithSteps = groundTruth.approaches.filter { $0.steps != nil }.count
        XCTAssertEqual(
            result.detected.steps.count,
            approachesWithSteps,
            "Expected \(approachesWithSteps) step sequences for IMG_4927"
        )

        for (i, stepSequence) in result.detected.steps.enumerated() {
            XCTAssertEqual(stepSequence.count, 4, "Approach \(i) should have 4 steps")
        }
    }
}
