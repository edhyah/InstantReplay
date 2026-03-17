import CoreMedia
import Foundation

struct DetectedEvent: Codable, Sendable {
    let timestamp: TimeInterval
}

struct TimestampComparison: Codable, Sendable {
    let detected: TimeInterval
    let expected: TimeInterval
    let delta: TimeInterval
    let withinTolerance: Bool
}

struct DetectionErrors: Codable, Sendable {
    var approachStart: [TimestampComparison] = []
    var takeoff: [TimestampComparison] = []
    var peak: [TimestampComparison] = []
    var landing: [TimestampComparison] = []
}

struct DetectedEvents: Codable, Sendable {
    var approachStarts: [DetectedEvent] = []
    var takeoffs: [DetectedEvent] = []
    var peaks: [DetectedEvent] = []
    var landings: [DetectedEvent] = []
}

struct StateTraceEntry: Codable, Sendable {
    let time: TimeInterval
    let state: String
}

struct ReplayDetectionResult: Codable, Sendable {
    let video: String
    let detected: DetectedEvents
    let errors: DetectionErrors
    let stateTrace: [StateTraceEntry]
    let passed: Bool
}

final class ReplayDetectionRunner {
    private let phaseTolerance: [String: TimeInterval] = [
        "approachStart": 0.5,
        "takeoff": 0.2,
        "peak": 0.2,
        "landing": 0.2
    ]

    func run(reader: PoseReplayReader, groundTruth: GroundTruth?) -> ReplayDetectionResult {
        print("DEBUG Runner: Starting run with \(reader.frameCount) frames")
        let mockTime = MockTimeProvider()
        let bodyTracker = BodyTracker()
        let stateMachine = ApproachDetectorStateMachine(timeProvider: mockTime)
        print("DEBUG Runner: Created state machine")

        var detected = DetectedEvents()
        var stateTrace: [StateTraceEntry] = []
        var previousState: ApproachState = .idle
        var currentFrameTimestamp: TimeInterval = 0

        stateMachine.onStateTransition = { state, time in
            stateTrace.append(StateTraceEntry(time: time, state: state.rawValue))
            switch state {
            case .approaching:
                detected.approachStarts.append(DetectedEvent(timestamp: time))
            case .ascending:
                detected.takeoffs.append(DetectedEvent(timestamp: time))
            case .descending:
                detected.peaks.append(DetectedEvent(timestamp: time))
            case .idle:
                // Landing: transition from descending to idle
                if previousState == .descending {
                    detected.landings.append(DetectedEvent(timestamp: currentFrameTimestamp))
                }
            }
            previousState = state
        }

        // Process frames through body tracker and state machine
        var lastTimestamp: TimeInterval = 0
        for frame in reader.frames() {
            let poseInterval: TimeInterval
            if lastTimestamp > 0 {
                poseInterval = frame.timestamp - lastTimestamp
            } else {
                poseInterval = 1.0 / 15.0
            }
            lastTimestamp = frame.timestamp
            currentFrameTimestamp = frame.timestamp

            mockTime.setTime(frame.timestamp)

            let trackingResult = bodyTracker.update(with: frame.observations, poseInterval: poseInterval)
            let dominantMover = trackingResult.trackedBodies.first {
                $0.id == trackingResult.dominantMoverID
            }

            let cmTimestamp = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
            _ = stateMachine.step(dominantMover: dominantMover, timestamp: cmTimestamp)
        }

        // Compare with ground truth
        var errors = DetectionErrors()
        var passed = true

        if let truth = groundTruth {
            let expectedApproachStarts = truth.approaches.map { $0.approachStart }
            let expectedTakeoffs = truth.approaches.map { $0.takeoff }
            let expectedPeaks = truth.approaches.map { $0.peak }
            let expectedLandings = truth.approaches.map { $0.landing }

            errors.approachStart = compareTimestamps(
                detected: detected.approachStarts.map { $0.timestamp },
                expected: expectedApproachStarts,
                tolerance: phaseTolerance["approachStart"]!
            )

            errors.takeoff = compareTimestamps(
                detected: detected.takeoffs.map { $0.timestamp },
                expected: expectedTakeoffs,
                tolerance: phaseTolerance["takeoff"]!
            )

            errors.peak = compareTimestamps(
                detected: detected.peaks.map { $0.timestamp },
                expected: expectedPeaks,
                tolerance: phaseTolerance["peak"]!
            )

            errors.landing = compareTimestamps(
                detected: detected.landings.map { $0.timestamp },
                expected: expectedLandings,
                tolerance: phaseTolerance["landing"]!
            )

            // Check if all comparisons pass
            let allComparisons = errors.approachStart + errors.takeoff + errors.peak + errors.landing
            let countMismatch = detected.approachStarts.count != truth.approaches.count
                || detected.takeoffs.count != truth.approaches.count
                || detected.peaks.count != truth.approaches.count
                || detected.landings.count != truth.approaches.count
            passed = allComparisons.allSatisfy { $0.withinTolerance } && !countMismatch
        }

        return ReplayDetectionResult(
            video: reader.videoInfo.filename,
            detected: detected,
            errors: errors,
            stateTrace: stateTrace,
            passed: passed
        )
    }

    private func compareTimestamps(
        detected: [TimeInterval],
        expected: [TimeInterval],
        tolerance: TimeInterval
    ) -> [TimestampComparison] {
        var comparisons: [TimestampComparison] = []

        let sortedDetected = detected.sorted()
        let sortedExpected = expected.sorted()

        for (d, e) in zip(sortedDetected, sortedExpected) {
            let delta = abs(d - e)
            comparisons.append(TimestampComparison(
                detected: d,
                expected: e,
                delta: delta,
                withinTolerance: delta <= tolerance
            ))
        }

        return comparisons
    }

    func outputJSON(_ result: ReplayDetectionResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(result),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"Failed to encode result\"}"
        }

        return json
    }
}
