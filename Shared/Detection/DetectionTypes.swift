import Vision

nonisolated struct BodyObservation: Sendable {
    let jointPoints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    let torsoCentroid: CGPoint
}
