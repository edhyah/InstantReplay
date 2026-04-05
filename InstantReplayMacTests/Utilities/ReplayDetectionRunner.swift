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

// MARK: - Step Detection Types

enum StepType: String, Codable, Sendable {
    case first
    case second
    case orientation
    case plant
}

enum DetectedFoot: String, Codable, Sendable {
    case left
    case right
    case unknown
}

struct StepEvent: Codable, Sendable {
    let type: StepType
    let timestamp: TimeInterval
    let foot: DetectedFoot
}

struct StepComparison: Codable, Sendable {
    let stepType: String
    let detected: TimeInterval?
    let expected: TimeInterval
    let delta: TimeInterval?
    let withinTolerance: Bool
    let footMatch: Bool
}

// MARK: - Detection Results

struct DetectionErrors: Codable, Sendable {
    var approachStart: [TimestampComparison] = []
    var takeoff: [TimestampComparison] = []
    var peak: [TimestampComparison] = []
    var landing: [TimestampComparison] = []
    var steps: [[StepComparison]] = []
}

struct DetectedEvents: Codable, Sendable {
    var approachStarts: [DetectedEvent] = []
    var takeoffs: [DetectedEvent] = []
    var peaks: [DetectedEvent] = []
    var landings: [DetectedEvent] = []
    var steps: [[StepEvent]] = []  // One array of 4 steps per approach
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
    private let stepTolerance: TimeInterval = 0.20

    func run(
        reader: PoseReplayReader,
        groundTruth: GroundTruth?,
        thresholds: StateMachineThresholds = StateMachineThresholds()
    ) -> ReplayDetectionResult {
        print("DEBUG Runner: Starting run with \(reader.frameCount) frames")
        let mockTime = MockTimeProvider()
        let bodyTracker = BodyTracker()
        let stateMachine = ApproachDetectorStateMachine(timeProvider: mockTime, thresholds: thresholds)
        let stepDetector = StepDetector()
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

            // Record ankle data for step detection
            if let mover = dominantMover {
                stepDetector.recordFrame(timestamp: frame.timestamp, jointPoints: mover.jointPoints)
            }

            let cmTimestamp = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
            _ = stateMachine.step(dominantMover: dominantMover, timestamp: cmTimestamp)
        }

        // Detect steps for each approach
        // Use a wider window since state machine's approachStart is often late
        // Look back 2 seconds from takeoff to capture all 4 steps
        let stepLookbackWindow: TimeInterval = 2.0
        let approachCount = detected.takeoffs.count
        for i in 0..<approachCount {
            let takeoff = detected.takeoffs[i].timestamp
            let approachStart = takeoff - stepLookbackWindow
            let detectedSteps = stepDetector.detectSteps(approachStart: approachStart, takeoff: takeoff)

            if detectedSteps.count == 4 {
                let stepTypes: [StepType] = [.first, .second, .orientation, .plant]
                let stepEvents = zip(stepTypes, detectedSteps).map { type, step in
                    StepEvent(
                        type: type,
                        timestamp: step.timestamp,
                        foot: DetectedFoot(rawValue: step.foot) ?? .unknown
                    )
                }
                detected.steps.append(stepEvents)
            }
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

            // Compare steps
            let approachesWithSteps = truth.approaches.filter { $0.steps != nil }
            for (i, approach) in approachesWithSteps.enumerated() {
                guard let expectedSteps = approach.steps else { continue }
                var stepComparisons: [StepComparison] = []

                let stepTypes: [(String, StepLabel)] = [
                    ("first", expectedSteps.first),
                    ("second", expectedSteps.second),
                    ("orientation", expectedSteps.orientation),
                    ("plant", expectedSteps.plant)
                ]

                for (j, (typeName, expected)) in stepTypes.enumerated() {
                    let detectedStep: StepEvent? = {
                        guard i < detected.steps.count, j < detected.steps[i].count else { return nil }
                        return detected.steps[i][j]
                    }()

                    let delta = detectedStep.map { abs($0.timestamp - expected.timestamp) }
                    let withinTolerance = delta.map { $0 <= stepTolerance } ?? false
                    let footMatch: Bool = {
                        guard let detected = detectedStep else { return false }
                        return detected.foot.rawValue == expected.foot.rawValue
                    }()

                    stepComparisons.append(StepComparison(
                        stepType: typeName,
                        detected: detectedStep?.timestamp,
                        expected: expected.timestamp,
                        delta: delta,
                        withinTolerance: withinTolerance,
                        footMatch: footMatch
                    ))
                }

                errors.steps.append(stepComparisons)
            }

            // Check if all comparisons pass
            let allComparisons = errors.approachStart + errors.takeoff + errors.peak + errors.landing
            let countMismatch = detected.approachStarts.count != truth.approaches.count
                || detected.takeoffs.count != truth.approaches.count
                || detected.peaks.count != truth.approaches.count
                || detected.landings.count != truth.approaches.count
            let stepsPass = errors.steps.allSatisfy { $0.allSatisfy { $0.withinTolerance && $0.footMatch } }
            let stepCountMatch = detected.steps.count == approachesWithSteps.count
            passed = allComparisons.allSatisfy { $0.withinTolerance } && !countMismatch && stepsPass && stepCountMatch
        }

        // Write step detector debug log
        stepDetector.writeDebugLog(to: "/tmp/step_detector_debug.log")

        // Log step comparison results
        var stepDebug: [String] = []
        stepDebug.append("Video: \(reader.videoInfo.filename)")
        stepDebug.append("Detected steps arrays: \(detected.steps.count)")
        for (i, stepSequence) in detected.steps.enumerated() {
            stepDebug.append("  Approach \(i) steps: \(stepSequence.map { "(\($0.type.rawValue):\($0.timestamp))" }.joined(separator: ", "))")
        }
        for (i, stepComparisons) in errors.steps.enumerated() {
            stepDebug.append("Approach \(i):")
            for comparison in stepComparisons {
                let detected = comparison.detected.map { String($0) } ?? "nil"
                let delta = comparison.delta.map { String($0) } ?? "nil"
                stepDebug.append("  \(comparison.stepType): detected=\(detected), expected=\(comparison.expected), delta=\(delta), withinTol=\(comparison.withinTolerance), footMatch=\(comparison.footMatch)")
            }
        }
        let existingLog = (try? String(contentsOfFile: "/tmp/step_comparison_debug.log")) ?? ""
        try? (existingLog + "\n---\n" + stepDebug.joined(separator: "\n")).write(toFile: "/tmp/step_comparison_debug.log", atomically: true, encoding: .utf8)

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
