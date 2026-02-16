import CoreMedia
import CoreVideo

struct MovementDetectionEvent: Sendable {
    let landingTimestamp: CMTime
}

nonisolated protocol MovementDetector: AnyObject, Sendable {
    func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime)
    var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)? { get set }
}
