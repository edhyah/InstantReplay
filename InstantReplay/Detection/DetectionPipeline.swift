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

    private nonisolated(unsafe) var lastPoseTimestamp: CMTime?
    private nonisolated(unsafe) var lastPoseWallTime: CFTimeInterval = 0
    private let timeProvider: TimeProvider

    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?
    nonisolated(unsafe) var onDetectionResult: ((DetectionPipelineResult) -> Void)?

    init(timeProvider: TimeProvider = SystemTimeProvider()) {
        self.timeProvider = timeProvider
        self.stateMachine = ApproachDetectorStateMachine(timeProvider: timeProvider)
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        processFrame(pixelBuffer, timestamp: timestamp, isFrontCamera: false)
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime, isFrontCamera: Bool) {
        let now = timeProvider.currentTime()
        let measuredInterval: Double
        if let previousTimestamp = lastPoseTimestamp {
            let mediaInterval = CMTimeGetSeconds(CMTimeSubtract(timestamp, previousTimestamp))
            if mediaInterval > 0 {
                measuredInterval = mediaInterval
            } else if lastPoseWallTime > 0 {
                measuredInterval = now - lastPoseWallTime
            } else {
                measuredInterval = 1.0 / 15.0
            }
        } else if lastPoseWallTime > 0 {
            measuredInterval = now - lastPoseWallTime
        } else {
            measuredInterval = 1.0 / 15.0 // default to ~15fps for first frame
        }
        lastPoseTimestamp = timestamp
        lastPoseWallTime = now

        let observations = poseEstimator.estimatePoses(pixelBuffer, isFrontCamera: isFrontCamera)
        let trackingResult = bodyTracker.update(with: observations, poseInterval: measuredInterval)

        let detectionFlag = DetectionFlag()
        stateMachine.onMovementDetected = { [weak self] event in
            detectionFlag.value = true
            self?.onMovementDetected?(event)
        }

        let debugInfo = stateMachine.step(trackedBodies: trackingResult.trackedBodies, timestamp: timestamp)

        let result = DetectionPipelineResult(
            trackingResult: trackingResult,
            stateMachineDebug: debugInfo,
            didDetectMovement: detectionFlag.value
        )
        onDetectionResult?(result)
    }

    func reset() {
        bodyTracker.reset()
        stateMachine.reset()
        lastPoseTimestamp = nil
        lastPoseWallTime = 0
    }
}

private final class DetectionFlag: @unchecked Sendable {
    nonisolated(unsafe) var value = false
}
