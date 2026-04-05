import CoreMedia
import CoreVideo

struct DetectionPipelineResult: Sendable {
    let trackingResult: BodyTrackingResult
    let stateMachineDebug: StateMachineDebugInfo
    let didDetectMovement: Bool
}

final class DetectionPipeline: MovementDetector, @unchecked Sendable {
    let poseEstimator = PoseEstimator()
    let bodyTracker = BodyTracker()
    let stateMachine: ApproachDetectorStateMachine
    let stepDetector = StepDetector()

    private nonisolated(unsafe) var lastPoseTimestamp: CFTimeInterval = 0
    private let timeProvider: TimeProvider
    private nonisolated(unsafe) var takeoffTimestamp: CMTime?
    private nonisolated(unsafe) var pendingTakeoff: Bool = false
    private nonisolated(unsafe) var lastVideoTimestamp: CMTime = .zero

    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?
    nonisolated(unsafe) var onDetectionResult: ((DetectionPipelineResult) -> Void)?

    init(timeProvider: TimeProvider = SystemTimeProvider()) {
        self.timeProvider = timeProvider
        self.stateMachine = ApproachDetectorStateMachine(timeProvider: timeProvider)

        // Track takeoff timing for step detection
        self.stateMachine.onStateTransition = { [weak self] state, time in
            debugLog("[DetectionPipeline] State transition: \(state.rawValue) at \(time)")
            if state == .ascending {
                // Flag that we need to capture the video timestamp on next frame
                self?.pendingTakeoff = true
                debugLog("[DetectionPipeline] Pending takeoff capture")
            }
        }
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let now = timeProvider.currentTime()
        let measuredInterval: Double
        if lastPoseTimestamp > 0 {
            measuredInterval = now - lastPoseTimestamp
        } else {
            measuredInterval = 1.0 / 15.0 // default to ~15fps for first frame
        }
        lastPoseTimestamp = now

        let observations = poseEstimator.estimatePoses(pixelBuffer)
        let trackingResult = bodyTracker.update(with: observations, poseInterval: measuredInterval)

        let dominantMover = trackingResult.trackedBodies.first {
            $0.id == trackingResult.dominantMoverID
        }

        // Record ankle data for step detection
        if let mover = dominantMover {
            stepDetector.recordFrame(timestamp: timestamp.seconds, jointPoints: mover.jointPoints)
        }

        // Track video timestamp for step detection
        lastVideoTimestamp = timestamp

        // Capture takeoff in video time (state transition already happened, now we have the video timestamp)
        if pendingTakeoff {
            takeoffTimestamp = timestamp
            pendingTakeoff = false
            debugLog("[DetectionPipeline] Captured takeoff at video time \(timestamp.seconds)")
        }

        var didDetect = false
        stateMachine.onMovementDetected = { [weak self] event in
            guard let self = self else { return }
            didDetect = true

            // Run step detection and enrich the event
            let steps = self.detectSteps()
            let enrichedEvent = MovementDetectionEvent(
                landingTimestamp: event.landingTimestamp,
                takeoffTimestamp: self.takeoffTimestamp,
                clipOriginTime: nil,  // Will be set by ClipExtractor
                steps: steps
            )
            self.onMovementDetected?(enrichedEvent)

            // Reset for next detection
            self.stepDetector.reset()
            self.takeoffTimestamp = nil
        }

        let debugInfo = stateMachine.step(dominantMover: dominantMover, timestamp: timestamp)

        let result = DetectionPipelineResult(
            trackingResult: trackingResult,
            stateMachineDebug: debugInfo,
            didDetectMovement: didDetect
        )
        onDetectionResult?(result)
    }

    func reset() {
        bodyTracker.reset()
        stateMachine.reset()
        stepDetector.reset()
        lastPoseTimestamp = 0
        takeoffTimestamp = nil
        pendingTakeoff = false
        lastVideoTimestamp = .zero
    }

    // MARK: - Step Detection

    private func detectSteps() -> [DetectedStepEvent] {
        guard let takeoff = takeoffTimestamp else {
            debugLog("[DetectionPipeline] detectSteps: no takeoff timestamp")
            return []
        }

        // Use 2-second lookback from takeoff (matching test runner)
        let lookbackWindow: TimeInterval = 2.0
        let approachStart = takeoff.seconds - lookbackWindow

        let detectedSteps = stepDetector.detectSteps(approachStart: approachStart, takeoff: takeoff.seconds)
        debugLog("[DetectionPipeline] detectSteps: found \(detectedSteps.count) steps from \(approachStart) to \(takeoff.seconds)")

        let stepTypes: [DetectedStepEvent.StepType] = [.first, .second, .orientation, .plant]
        let result = zip(stepTypes, detectedSteps).map { type, step in
            DetectedStepEvent(type: type, timestamp: step.timestamp)
        }

        for step in result {
            debugLog("[DetectionPipeline]   step: \(step.type.rawValue) at \(step.timestamp)")
        }

        return result
    }
}
