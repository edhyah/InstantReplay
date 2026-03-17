import AVFoundation
import CoreMedia
import Foundation
import Vision

final class PoseCaptureWriter {
    private let videoURL: URL
    private let outputURL: URL

    init(videoURL: URL, outputURL: URL) {
        self.videoURL = videoURL
        self.outputURL = outputURL
    }

    func capture() throws {
        let asset = AVAsset(url: videoURL)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw PoseCaptureError.noVideoTrack
        }

        let reader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            throw PoseCaptureError.cannotAddTrackOutput
        }
        reader.add(trackOutput)
        reader.startReading()

        let frameRate = Double(videoTrack.nominalFrameRate)
        let duration = CMTimeGetSeconds(asset.duration)
        let subsampleRate = max(1, Int(round(frameRate / 15.0)))

        var frames: [CapturedFrame] = []
        var frameIndex = 0
        var processedCount = 0

        while reader.status == .reading {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                break
            }

            // Subsample to ~15fps
            if frameIndex % subsampleRate == 0 {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let timestampSeconds = CMTimeGetSeconds(timestamp)

                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let observations = estimatePoses(pixelBuffer)
                    let capturedObservations = observations.map { obs in
                        CapturedObservation(
                            torsoCentroid: CodablePoint(obs.torsoCentroid),
                            joints: JointNameCodable.encode(obs.jointPoints)
                        )
                    }
                    frames.append(CapturedFrame(timestamp: timestampSeconds, observations: capturedObservations))
                }
                processedCount += 1
            }

            frameIndex += 1
        }

        if reader.status == .failed {
            throw PoseCaptureError.readerFailed(reader.error)
        }

        let videoInfo = VideoInfo(
            filename: videoURL.lastPathComponent,
            duration: duration,
            frameRate: frameRate,
            frameCount: processedCount
        )

        let capturedData = CapturedPoseData(videoInfo: videoInfo, frames: frames)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(capturedData)
        try jsonData.write(to: outputURL)
    }

    private func estimatePoses(_ pixelBuffer: CVPixelBuffer) -> [CapturedBodyObservation] {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        guard let results = request.results, !results.isEmpty else {
            return []
        }

        var observations: [CapturedBodyObservation] = []
        for poseObservation in results {
            guard let body = buildBodyObservation(from: poseObservation) else { continue }
            observations.append(body)
        }

        return observations
    }

    private func buildBodyObservation(from pose: VNHumanBodyPoseObservation) -> CapturedBodyObservation? {
        guard let allPoints = try? pose.recognizedPoints(.all) else { return nil }

        var jointPoints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]
        let minimumConfidence: Float = 0.1

        for (jointName, point) in allPoints {
            if point.confidence >= minimumConfidence {
                // Convert from Vision coordinates (origin bottom-left) to
                // UIKit-style coordinates (origin top-left)
                jointPoints[jointName] = CGPoint(x: point.location.x, y: 1.0 - point.location.y)
            }
        }

        guard let centroid = computeTorsoCentroid(from: jointPoints) else { return nil }

        return CapturedBodyObservation(jointPoints: jointPoints, torsoCentroid: centroid)
    }

    private func computeTorsoCentroid(from joints: [VNHumanBodyPoseObservation.JointName: CGPoint]) -> CGPoint? {
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

        guard count >= 2 else { return nil }
        return CGPoint(x: sumX / count, y: sumY / count)
    }
}

private struct CapturedBodyObservation {
    let jointPoints: [VNHumanBodyPoseObservation.JointName: CGPoint]
    let torsoCentroid: CGPoint
}

enum PoseCaptureError: Error, CustomStringConvertible {
    case noVideoTrack
    case cannotAddTrackOutput
    case readerFailed(Error?)

    var description: String {
        switch self {
        case .noVideoTrack:
            return "No video track found in asset"
        case .cannotAddTrackOutput:
            return "Cannot add track output to reader"
        case .readerFailed(let error):
            return "Asset reader failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
