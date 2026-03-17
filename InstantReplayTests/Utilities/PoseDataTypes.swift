import CoreGraphics
import Foundation

struct CodablePoint: Codable, Sendable {
    let x: CGFloat
    let y: CGFloat

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

struct VideoInfo: Codable, Sendable {
    let filename: String
    let duration: TimeInterval
    let frameRate: Double
    let frameCount: Int
}

struct CapturedObservation: Codable, Sendable {
    let torsoCentroid: CodablePoint
    let joints: [String: CodablePoint]
}

struct CapturedFrame: Codable, Sendable {
    let timestamp: TimeInterval
    let observations: [CapturedObservation]
}

struct CapturedPoseData: Codable, Sendable {
    let videoInfo: VideoInfo
    let frames: [CapturedFrame]
}
