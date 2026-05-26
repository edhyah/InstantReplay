import Foundation

struct ApproachLabel: Codable {
    let approachStart: TimeInterval
    let steps: ApproachSteps?
    let takeoff: TimeInterval
    let peak: TimeInterval
    let landing: TimeInterval
}

struct ApproachSteps: Codable {
    let first: StepLabel
    let second: StepLabel
    let orientation: StepLabel
    let plant: StepLabel
}

struct StepLabel: Codable {
    let timestamp: TimeInterval
    let foot: String
}

struct GroundTruth: Codable {
    let approaches: [ApproachLabel]
}
