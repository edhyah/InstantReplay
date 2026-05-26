import AVFoundation
import CoreMedia
import CoreVideo

struct FrameMetadata: Sendable {
    let isFrontCamera: Bool

    static let backCamera = FrameMetadata(isFrontCamera: false)
}

protocol MediaSourceSession: AnyObject {
    var onDetectionUpdate: (@Sendable (DetectionUpdate) -> Void)? { get set }
    var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)? { get set }

    func start()
    func stop()
    func extractClip(jumpTimestamp: CMTime, completion: @escaping @Sendable (ClipAsset?) -> Void)
}

enum DetectionSamplingPolicy: Sendable {
    case everyNthFrame(Int)
    case minimumInterval(TimeInterval)
}

final class DetectionCoordinator: @unchecked Sendable {
    private let detectionPipeline = DetectionPipeline()
    private let detectionQueue: DispatchQueue
    private let samplingPolicy: DetectionSamplingPolicy

    private nonisolated(unsafe) var frameCounter = 0
    private nonisolated(unsafe) var lastDetectionTimestamp: CMTime?

    nonisolated(unsafe) var onDetectionUpdate: (@Sendable (DetectionUpdate) -> Void)?
    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?

    nonisolated init(label: String, samplingPolicy: DetectionSamplingPolicy) {
        self.detectionQueue = DispatchQueue(label: label, qos: .userInitiated)
        self.samplingPolicy = samplingPolicy
    }

    nonisolated func process(sampleBuffer: CMSampleBuffer, metadata: FrameMetadata, measuredFPS: Double) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard shouldRunDetection(at: timestamp),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        nonisolated(unsafe) let buffer = pixelBuffer
        detectionQueue.async { [self] in
            detectionPipeline.onMovementDetected = { [self] event in
                onMovementDetected?(event)
            }

            detectionPipeline.onDetectionResult = { [self] result in
                let update = DetectionUpdate(
                    trackingResult: result.trackingResult,
                    stateMachineDebug: result.stateMachineDebug,
                    detectionFlash: result.didDetectMovement,
                    captureFPS: measuredFPS
                )
                onDetectionUpdate?(update)
            }

            detectionPipeline.processFrame(buffer, timestamp: timestamp, isFrontCamera: metadata.isFrontCamera)
        }
    }

    nonisolated func reset() {
        detectionPipeline.reset()
        frameCounter = 0
        lastDetectionTimestamp = nil
    }

    private nonisolated func shouldRunDetection(at timestamp: CMTime) -> Bool {
        switch samplingPolicy {
        case .everyNthFrame(let rate):
            frameCounter += 1
            return frameCounter % max(1, rate) == 0

        case .minimumInterval(let interval):
            guard let lastDetectionTimestamp else {
                lastDetectionTimestamp = timestamp
                return true
            }

            let elapsed = CMTimeGetSeconds(CMTimeSubtract(timestamp, lastDetectionTimestamp))
            guard elapsed >= interval else { return false }
            self.lastDetectionTimestamp = timestamp
            return true
        }
    }
}
