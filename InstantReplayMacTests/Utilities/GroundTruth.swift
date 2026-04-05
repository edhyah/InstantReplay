import Foundation

enum Foot: String, Codable {
    case left
    case right
}

struct StepLabel: Codable {
    let timestamp: TimeInterval
    let foot: Foot
}

struct StepsLabel: Codable {
    let first: StepLabel
    let second: StepLabel
    let orientation: StepLabel
    let plant: StepLabel
}

struct ApproachLabel: Codable {
    let approachStart: TimeInterval
    let steps: StepsLabel?  // Optional for backwards compatibility
    let takeoff: TimeInterval
    let peak: TimeInterval
    let landing: TimeInterval
}

struct GroundTruth: Codable {
    let approaches: [ApproachLabel]
}
