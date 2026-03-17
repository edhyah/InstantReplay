import Foundation
import Vision

final class PoseReplayReader {
    let capturedData: CapturedPoseData

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        capturedData = try JSONDecoder().decode(CapturedPoseData.self, from: data)
    }

    init(data: CapturedPoseData) {
        self.capturedData = data
    }

    var videoInfo: VideoInfo {
        capturedData.videoInfo
    }

    var frameCount: Int {
        capturedData.frames.count
    }

    func frames() -> ReplayFrameSequence {
        ReplayFrameSequence(frames: capturedData.frames)
    }
}

struct ReplayFrame {
    let timestamp: TimeInterval
    let observations: [BodyObservation]
}

struct ReplayFrameSequence: Sequence {
    let frames: [CapturedFrame]

    func makeIterator() -> ReplayFrameIterator {
        ReplayFrameIterator(frames: frames)
    }
}

struct ReplayFrameIterator: IteratorProtocol {
    private let frames: [CapturedFrame]
    private var index = 0

    init(frames: [CapturedFrame]) {
        self.frames = frames
    }

    mutating func next() -> ReplayFrame? {
        guard index < frames.count else { return nil }

        let capturedFrame = frames[index]
        index += 1

        let observations = capturedFrame.observations.map { capturedObs in
            BodyObservation(
                jointPoints: JointNameCodable.decode(capturedObs.joints),
                torsoCentroid: capturedObs.torsoCentroid.cgPoint
            )
        }

        return ReplayFrame(timestamp: capturedFrame.timestamp, observations: observations)
    }
}
