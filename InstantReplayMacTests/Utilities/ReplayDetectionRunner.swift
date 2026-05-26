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

struct PhaseCountMismatch: Codable, Sendable {
    let phase: String
    let detected: Int
    let expected: Int
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
    let countMismatches: [PhaseCountMismatch]
    let stateTrace: [StateTraceEntry]
    let passed: Bool
    let failureSummary: String?
}

final class ReplayDetectionRunner {
    private let phaseTolerance: [String: TimeInterval] = [
        "approachStart": 0.5,
        "takeoff": 0.2,
        "peak": 0.2,
        "landing": 0.3
    ]

    func run(
        reader: PoseReplayReader,
        groundTruth: GroundTruth?,
        thresholds: StateMachineThresholds = StateMachineThresholds()
    ) -> ReplayDetectionResult {
        let mockTime = MockTimeProvider()
        let bodyTracker = BodyTracker()
        let stateMachine = ApproachDetectorStateMachine(timeProvider: mockTime, thresholds: thresholds)

        var detected = DetectedEvents()
        let detectedTakeoffs = DetectedEventRecorder()
        var stateTrace: [StateTraceEntry] = []
        var previousState: ApproachState = .idle
        var currentFrameTimestamp: TimeInterval = 0

        stateMachine.onStateTransition = { state, time in
            stateTrace.append(StateTraceEntry(time: time, state: state.rawValue))
            switch state {
            case .approaching:
                detected.approachStarts.append(DetectedEvent(timestamp: time))
            case .ascending:
                break
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

        stateMachine.onMovementDetected = { event in
            detectedTakeoffs.append(DetectedEvent(timestamp: event.jumpTimestamp.seconds))
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

            let cmTimestamp = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
            _ = stateMachine.step(trackedBodies: trackingResult.trackedBodies, timestamp: cmTimestamp)
        }
        detected.takeoffs = detectedTakeoffs.events

        // Compare with ground truth
        var errors = DetectionErrors()
        var countMismatches: [PhaseCountMismatch] = []
        var passed = true
        var failureSummary: String?

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

            countMismatches = makeCountMismatches(
                detected: detected,
                expectedTakeoffCount: expectedTakeoffs.count,
                expectedPeakCount: expectedPeaks.count,
                expectedLandingCount: expectedLandings.count
            )

            let allComparisons = errors.takeoff + errors.peak + errors.landing
            passed = allComparisons.allSatisfy { $0.withinTolerance } && countMismatches.isEmpty
            failureSummary = passed ? nil : makeFailureSummary(
                video: reader.videoInfo.filename,
                detected: detected,
                expectedApproachStarts: expectedApproachStarts,
                expectedTakeoffs: expectedTakeoffs,
                expectedPeaks: expectedPeaks,
                expectedLandings: expectedLandings,
                errors: errors,
                countMismatches: countMismatches
            )
        }

        return ReplayDetectionResult(
            video: reader.videoInfo.filename,
            detected: detected,
            errors: errors,
            countMismatches: countMismatches,
            stateTrace: stateTrace,
            passed: passed,
            failureSummary: failureSummary
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

    private func makeCountMismatches(
        detected: DetectedEvents,
        expectedTakeoffCount: Int,
        expectedPeakCount: Int,
        expectedLandingCount: Int
    ) -> [PhaseCountMismatch] {
        [
            ("takeoff", detected.takeoffs.count, expectedTakeoffCount),
            ("peak", detected.peaks.count, expectedPeakCount),
            ("landing", detected.landings.count, expectedLandingCount)
        ].compactMap { phase, detected, expected in
            detected == expected ? nil : PhaseCountMismatch(phase: phase, detected: detected, expected: expected)
        }
    }

    private func makeFailureSummary(
        video: String,
        detected: DetectedEvents,
        expectedApproachStarts: [TimeInterval],
        expectedTakeoffs: [TimeInterval],
        expectedPeaks: [TimeInterval],
        expectedLandings: [TimeInterval],
        errors: DetectionErrors,
        countMismatches: [PhaseCountMismatch]
    ) -> String {
        var lines = ["\(video) failed:"]

        for mismatch in countMismatches {
            lines.append("  \(mismatch.phase) count: detected \(mismatch.detected), expected \(mismatch.expected)")
        }

        lines.append("  approachStart expected \(format(expectedApproachStarts)), detected \(format(detected.approachStarts.map { $0.timestamp }))")
        lines.append("  takeoff expected \(format(expectedTakeoffs)), detected \(format(detected.takeoffs.map { $0.timestamp }))")
        lines.append("  peak expected \(format(expectedPeaks)), detected \(format(detected.peaks.map { $0.timestamp }))")
        lines.append("  landing expected \(format(expectedLandings)), detected \(format(detected.landings.map { $0.timestamp }))")

        appendOutOfTolerance(errors.approachStart, phase: "approachStart", to: &lines)
        appendOutOfTolerance(errors.takeoff, phase: "takeoff", to: &lines)
        appendOutOfTolerance(errors.peak, phase: "peak", to: &lines)
        appendOutOfTolerance(errors.landing, phase: "landing", to: &lines)

        return lines.joined(separator: "\n")
    }

    private func appendOutOfTolerance(_ comparisons: [TimestampComparison], phase: String, to lines: inout [String]) {
        for comparison in comparisons where !comparison.withinTolerance {
            lines.append(
                String(
                    format: "  %@ off by %.3fs: detected %.3f, expected %.3f",
                    phase,
                    comparison.delta,
                    comparison.detected,
                    comparison.expected
                )
            )
        }
    }

    private func format(_ values: [TimeInterval]) -> String {
        "[" + values.map { String(format: "%.3f", $0) }.joined(separator: ", ") + "]"
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

private final class DetectedEventRecorder: @unchecked Sendable {
    private(set) var events: [DetectedEvent] = []

    func append(_ event: DetectedEvent) {
        events.append(event)
    }
}
