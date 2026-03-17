import CoreGraphics
import Foundation

struct ThresholdRange {
    let name: String
    let min: CGFloat
    let max: CGFloat
    let step: CGFloat

    var values: [CGFloat] {
        var result: [CGFloat] = []
        var current = min
        while current <= max + step / 2 {
            result.append(current)
            current += step
        }
        return result
    }

    var count: Int { values.count }
}

struct TuningResult: Comparable {
    let thresholds: StateMachineThresholds
    let totalError: TimeInterval
    let maxError: TimeInterval
    let passRate: Double
    let perPhaseErrors: [String: TimeInterval]
    let detectionCount: Int
    let expectedCount: Int

    static func < (lhs: TuningResult, rhs: TuningResult) -> Bool {
        // Prioritize pass rate, then minimize total error
        if lhs.passRate != rhs.passRate {
            return lhs.passRate > rhs.passRate
        }
        return lhs.totalError < rhs.totalError
    }
}

struct TestVideo {
    let reader: PoseReplayReader
    let groundTruth: GroundTruth
}

final class TuningSession {
    private let videos: [TestVideo]
    private let runner = ReplayDetectionRunner()

    init(videos: [TestVideo]) {
        self.videos = videos
    }

    func evaluate(thresholds: StateMachineThresholds) -> TuningResult {
        var totalError: TimeInterval = 0
        var maxError: TimeInterval = 0
        var passCount = 0
        var totalVideos = 0
        var detectionCount = 0
        var expectedCount = 0
        var phaseErrors: [String: TimeInterval] = [
            "approachStart": 0,
            "takeoff": 0,
            "peak": 0,
            "landing": 0
        ]

        for video in videos {
            totalVideos += 1
            let result = runner.run(reader: video.reader, groundTruth: video.groundTruth, thresholds: thresholds)

            if result.passed {
                passCount += 1
            }

            detectionCount += result.detected.landings.count
            expectedCount += video.groundTruth.approaches.count

            // Accumulate errors
            for comparison in result.errors.approachStart {
                totalError += comparison.delta
                maxError = max(maxError, comparison.delta)
                phaseErrors["approachStart"]! += comparison.delta
            }
            for comparison in result.errors.takeoff {
                totalError += comparison.delta
                maxError = max(maxError, comparison.delta)
                phaseErrors["takeoff"]! += comparison.delta
            }
            for comparison in result.errors.peak {
                totalError += comparison.delta
                maxError = max(maxError, comparison.delta)
                phaseErrors["peak"]! += comparison.delta
            }
            for comparison in result.errors.landing {
                totalError += comparison.delta
                maxError = max(maxError, comparison.delta)
                phaseErrors["landing"]! += comparison.delta
            }
        }

        return TuningResult(
            thresholds: thresholds,
            totalError: totalError,
            maxError: maxError,
            passRate: totalVideos > 0 ? Double(passCount) / Double(totalVideos) : 0,
            perPhaseErrors: phaseErrors,
            detectionCount: detectionCount,
            expectedCount: expectedCount
        )
    }
}

struct GridSearchConfig {
    let approachHorizontalVelocity: ThresholdRange
    let ascendingVerticalVelocity: ThresholdRange
    let descendingVerticalVelocity: ThresholdRange
    let landingVerticalMagnitude: ThresholdRange

    var totalCombinations: Int {
        approachHorizontalVelocity.count *
            ascendingVerticalVelocity.count *
            descendingVerticalVelocity.count *
            landingVerticalMagnitude.count
    }
}

final class GridSearcher {
    private let session: TuningSession
    private let config: GridSearchConfig
    private let defaults = StateMachineThresholds()
    private let regularizationWeight: CGFloat

    init(session: TuningSession, config: GridSearchConfig, regularizationWeight: CGFloat = 0.1) {
        self.session = session
        self.config = config
        self.regularizationWeight = regularizationWeight
    }

    func search(progressCallback: ((Int, Int) -> Void)? = nil) -> [TuningResult] {
        var results: [TuningResult] = []
        var evaluated = 0
        let total = config.totalCombinations

        for approachVel in config.approachHorizontalVelocity.values {
            for ascendingVel in config.ascendingVerticalVelocity.values {
                for descendingVel in config.descendingVerticalVelocity.values {
                    for landingMag in config.landingVerticalMagnitude.values {
                        let thresholds = StateMachineThresholds(
                            approachHorizontalVelocity: approachVel,
                            ascendingVerticalVelocity: ascendingVel,
                            descendingVerticalVelocity: descendingVel,
                            landingVerticalMagnitude: landingMag
                        )

                        let result = session.evaluate(thresholds: thresholds)
                        results.append(result)

                        evaluated += 1
                        progressCallback?(evaluated, total)
                    }
                }
            }
        }

        return results.sorted()
    }

    func formatResult(_ result: TuningResult, rank: Int) -> String {
        let t = result.thresholds
        return """
        #\(rank): Pass Rate: \(String(format: "%.0f%%", result.passRate * 100)) | Total Error: \(String(format: "%.3fs", result.totalError)) | Max Error: \(String(format: "%.3fs", result.maxError))
           Detections: \(result.detectionCount)/\(result.expectedCount)
           Phase Errors: approach=\(String(format: "%.3fs", result.perPhaseErrors["approachStart"] ?? 0)), takeoff=\(String(format: "%.3fs", result.perPhaseErrors["takeoff"] ?? 0)), peak=\(String(format: "%.3fs", result.perPhaseErrors["peak"] ?? 0)), landing=\(String(format: "%.3fs", result.perPhaseErrors["landing"] ?? 0))
           Thresholds:
             approachHorizontalVelocity: \(String(format: "%.2f", t.approachHorizontalVelocity))
             ascendingVerticalVelocity: \(String(format: "%.2f", t.ascendingVerticalVelocity))
             descendingVerticalVelocity: \(String(format: "%.2f", t.descendingVerticalVelocity))
             landingVerticalMagnitude: \(String(format: "%.2f", t.landingVerticalMagnitude))
        """
    }

    func generateCodeSnippet(_ result: TuningResult) -> String {
        let t = result.thresholds
        return """
        StateMachineThresholds(
            approachHorizontalVelocity: \(String(format: "%.2f", t.approachHorizontalVelocity)),
            ascendingVerticalVelocity: \(String(format: "%.2f", t.ascendingVerticalVelocity)),
            descendingVerticalVelocity: \(String(format: "%.2f", t.descendingVerticalVelocity)),
            landingVerticalMagnitude: \(String(format: "%.2f", t.landingVerticalMagnitude))
        )
        """
    }
}
