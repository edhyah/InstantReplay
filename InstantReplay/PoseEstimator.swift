import CoreMedia
import CoreVideo
import Vision

nonisolated struct BodyObservation: Sendable {
    let jointPoints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    let torsoCentroid: CGPoint
}

final class PoseEstimator: @unchecked Sendable {
    private let detectionQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.detection", qos: .userInitiated)

    private nonisolated(unsafe) var _latestObservations: [BodyObservation] = []
    private let observationsLock = NSLock()

    nonisolated var latestObservations: [BodyObservation] {
        observationsLock.lock()
        defer { observationsLock.unlock() }
        return _latestObservations
    }

    nonisolated(unsafe) var onPoseUpdate: (@Sendable ([BodyObservation]) -> Void)?

    nonisolated func processFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        nonisolated(unsafe) let buffer = pixelBuffer
        detectionQueue.async { [self] in
            self.runPoseEstimation(buffer)
        }
    }

    private nonisolated func runPoseEstimation(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanBodyPoseRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let results = request.results, !results.isEmpty else {
            updateObservations([])
            return
        }

        var observations: [BodyObservation] = []
        for poseObservation in results {
            guard let body = buildBodyObservation(from: poseObservation) else { continue }
            observations.append(body)
        }

        updateObservations(observations)
    }

    private nonisolated func buildBodyObservation(from pose: VNHumanBodyPoseObservation) -> BodyObservation? {
        guard let allPoints = try? pose.recognizedPoints(.all) else { return nil }

        // Collect recognized joint positions (Vision coordinates: origin bottom-left, 0-1 normalized)
        var jointPoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        let minimumConfidence: Float = 0.1

        for (jointName, point) in allPoints {
            if point.confidence >= minimumConfidence {
                // Convert from Vision coordinates (origin bottom-left) to
                // UIKit-style coordinates (origin top-left) for rendering
                jointPoints[jointName] = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
            }
        }

        // Derive torso centroid from available shoulder and hip points
        guard let centroid = computeTorsoCentroid(from: jointPoints) else { return nil }

        return BodyObservation(jointPoints: jointPoints, torsoCentroid: centroid)
    }

    private nonisolated func computeTorsoCentroid(from joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGPoint? {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var count: CGFloat = 0

        let torsoJoints: [VNHumanBodyPoseObservation.JointName] = [
            .leftShoulder, .rightShoulder, .leftHip, .rightHip
        ]

        for joint in torsoJoints {
            if let point = joints[joint] {
                sumX += point.x
                sumY += point.y
                count += 1
            }
        }

        // Need at least 2 torso joints to compute a meaningful centroid
        guard count >= 2 else { return nil }
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    private nonisolated func updateObservations(_ observations: [BodyObservation]) {
        observationsLock.lock()
        _latestObservations = observations
        observationsLock.unlock()

        onPoseUpdate?(observations)
    }
}
