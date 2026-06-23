import CoreGraphics
import CoreVideo
import QuartzCore
import Vision

struct PoseEstimationResult: Sendable {
    let observations: [BodyObservation]
    let rawPoseCount: Int
}

final class PoseEstimator: Sendable {
    private nonisolated(unsafe) var lastVisionErrorLogTime: CFTimeInterval = 0

    nonisolated func estimatePoses(_ pixelBuffer: CVPixelBuffer, isFrontCamera: Bool = false) -> [BodyObservation] {
        estimatePoseResult(pixelBuffer, isFrontCamera: isFrontCamera).observations
    }

    nonisolated func estimatePoseResult(_ pixelBuffer: CVPixelBuffer, isFrontCamera: Bool = false) -> PoseEstimationResult {
        let request = VNDetectHumanBodyPoseRequest()

        // Front camera pixel buffers are rotated 180 degrees relative to back camera
        let orientation: CGImagePropertyOrientation = isFrontCamera ? .down : .up
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logVisionError(error)
            return PoseEstimationResult(observations: [], rawPoseCount: 0)
        }

        guard let results = request.results, !results.isEmpty else {
            return PoseEstimationResult(observations: [], rawPoseCount: 0)
        }

        var observations: [BodyObservation] = []
        for poseObservation in results {
            guard let body = buildBodyObservation(from: poseObservation) else { continue }
            observations.append(body)
        }

        return PoseEstimationResult(observations: observations, rawPoseCount: results.count)
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

    private nonisolated func logVisionError(_ error: Error) {
        let now = CACurrentMediaTime()
        guard now - lastVisionErrorLogTime >= 1.0 else { return }
        lastVisionErrorLogTime = now

        let nsError = error as NSError
        debugLog("[PoseEstimator] Vision error domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), userInfo=\(nsError.userInfo)")
    }
}
