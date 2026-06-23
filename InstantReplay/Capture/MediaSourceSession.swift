import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore

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
    private let label: String

    private nonisolated(unsafe) var frameCounter = 0
    private nonisolated(unsafe) var lastDetectionTimestamp: CMTime?
    private nonisolated(unsafe) var logWindowStartTime: CFTimeInterval = 0
    private nonisolated(unsafe) var logWindowFrameCount = 0

    nonisolated(unsafe) var onDetectionUpdate: (@Sendable (DetectionUpdate) -> Void)?
    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?

    nonisolated init(label: String, samplingPolicy: DetectionSamplingPolicy) {
        self.detectionQueue = DispatchQueue(label: label, qos: .userInitiated)
        self.samplingPolicy = samplingPolicy
        self.label = label
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
                logDetectionSummary(result: result, timestamp: timestamp, measuredFPS: measuredFPS, metadata: metadata)

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
        logWindowStartTime = 0
        logWindowFrameCount = 0
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

    private nonisolated func logDetectionSummary(
        result: DetectionPipelineResult,
        timestamp: CMTime,
        measuredFPS: Double,
        metadata: FrameMetadata
    ) {
        let now = CACurrentMediaTime()
        if logWindowStartTime == 0 {
            logWindowStartTime = now
        }
        logWindowFrameCount += 1

        let elapsed = now - logWindowStartTime
        guard elapsed >= 1.0 else { return }

        let poseFPS = Double(logWindowFrameCount) / elapsed
        logWindowStartTime = now
        logWindowFrameCount = 0

        let bodies = result.trackingResult.trackedBodies
        let maxHorizontalVelocity = bodies.map { abs($0.horizontalVelocity) }.max() ?? 0
        let minVerticalVelocity = bodies.map(\.verticalVelocity).min() ?? 0
        let maxVerticalVelocity = bodies.map(\.verticalVelocity).max() ?? 0
        let dominantID = result.trackingResult.dominantMoverID.map(String.init) ?? "nil"

        debugLog(String(
            format: "[Detection] label=%@ ts=%.3f camera=%@ captureFPS=%.1f poseFPS=%.1f poseDt=%.3f rawPoses=%d acceptedPoses=%d trackedBodies=%d dominant=%@ state=%@ maxAbsH=%.3f minV=%.3f maxV=%.3f detected=%@",
            label,
            timestamp.seconds,
            metadata.isFrontCamera ? "front" : "back",
            measuredFPS,
            poseFPS,
            result.poseInterval,
            result.rawPoseCount,
            result.acceptedPoseCount,
            bodies.count,
            dominantID,
            result.stateMachineDebug.state.rawValue,
            Double(maxHorizontalVelocity),
            Double(minVerticalVelocity),
            Double(maxVerticalVelocity),
            result.didDetectMovement ? "true" : "false"
        ))
    }
}
