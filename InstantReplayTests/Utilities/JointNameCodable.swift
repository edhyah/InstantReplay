import Vision

enum JointNameCodable {
    private static let jointNameToString: [VNHumanBodyPoseObservation.JointName: String] = [
        .nose: "nose",
        .leftEye: "leftEye",
        .rightEye: "rightEye",
        .leftEar: "leftEar",
        .rightEar: "rightEar",
        .leftShoulder: "leftShoulder",
        .rightShoulder: "rightShoulder",
        .neck: "neck",
        .leftElbow: "leftElbow",
        .rightElbow: "rightElbow",
        .leftWrist: "leftWrist",
        .rightWrist: "rightWrist",
        .leftHip: "leftHip",
        .rightHip: "rightHip",
        .root: "root",
        .leftKnee: "leftKnee",
        .rightKnee: "rightKnee",
        .leftAnkle: "leftAnkle",
        .rightAnkle: "rightAnkle"
    ]

    private static let stringToJointName: [String: VNHumanBodyPoseObservation.JointName] = {
        Dictionary(uniqueKeysWithValues: jointNameToString.map { ($1, $0) })
    }()

    static func string(from jointName: VNHumanBodyPoseObservation.JointName) -> String {
        jointNameToString[jointName] ?? jointName.rawValue.rawValue
    }

    static func jointName(from string: String) -> VNHumanBodyPoseObservation.JointName? {
        stringToJointName[string]
    }

    static func encode(_ joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> [String: CodablePoint] {
        var result: [String: CodablePoint] = [:]
        for (jointName, point) in joints {
            result[string(from: jointName)] = CodablePoint(point)
        }
        return result
    }

    static func decode(_ joints: [String: CodablePoint]) -> [VNHumanBodyPoseObservation.JointName: CGPoint] {
        var result: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        for (string, point) in joints {
            if let jointName = jointName(from: string) {
                result[jointName] = point.cgPoint
            }
        }
        return result
    }
}
