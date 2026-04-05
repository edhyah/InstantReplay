import CoreMedia
import CoreVideo

struct DetectedStepEvent: Sendable {
    enum StepType: String, Sendable {
        case first, second, orientation, plant
    }
    let type: StepType
    let timestamp: TimeInterval
}

struct MovementDetectionEvent: Sendable {
    let landingTimestamp: CMTime
    let takeoffTimestamp: CMTime?
    let clipOriginTime: CMTime?
    let steps: [DetectedStepEvent]
}

nonisolated protocol MovementDetector: AnyObject, Sendable {
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime)
    var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)? { get set }
}
