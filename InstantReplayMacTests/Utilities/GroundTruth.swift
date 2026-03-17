import Foundation

struct ApproachLabel: Codable {
    let approachStart: TimeInterval
    let takeoff: TimeInterval
    let peak: TimeInterval
    let landing: TimeInterval
}

struct GroundTruth: Codable {
    let approaches: [ApproachLabel]
}
