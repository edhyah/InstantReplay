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

    private nonisolated(unsafe) var lastPoseTimestamp: CFTimeInterval = 0
    private let timeProvider: TimeProvider

    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?
    nonisolated(unsafe) var onDetectionResult: ((DetectionPipelineResult) -> Void)?

    init(timeProvider: TimeProvider = SystemTimeProvider()) {
        self.timeProvider = timeProvider
        self.stateMachine = ApproachDetectorStateMachine(timeProvider: timeProvider)
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

        var didDetect = false
        stateMachine.onMovementDetected = { [weak self] event in
            didDetect = true
            self?.onMovementDetected?(event)
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
        lastPoseTimestamp = 0
    }
}
