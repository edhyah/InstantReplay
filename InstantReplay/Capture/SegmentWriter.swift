import AVFoundation
import CoreMedia

final class SegmentWriter: @unchecked Sendable {
    nonisolated let fileURL: URL
    nonisolated let startTimestamp: CMTime

    private nonisolated(unsafe) let assetWriter: AVAssetWriter
    private nonisolated(unsafe) let videoInput: AVAssetWriterInput
    private nonisolated(unsafe) var isFinalized = false

    nonisolated init?(outputURL: URL, startTimestamp: CMTime, sourceFormatDescription: CMFormatDescription) {
        self.fileURL = outputURL
        self.startTimestamp = startTimestamp

        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            return nil
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(sourceFormatDescription)

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(dimensions.width),
            AVVideoHeightKey: Int(dimensions.height),
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = true

        guard assetWriter.canAdd(videoInput) else { return nil }
        assetWriter.add(videoInput)

        guard assetWriter.startWriting() else { return nil }
        assetWriter.startSession(atSourceTime: startTimestamp)
    }

    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinalized, videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }

    nonisolated func finalize(completion: @escaping @Sendable () -> Void) {
        guard !isFinalized else {
            completion()
            return
        }
        isFinalized = true

        videoInput.markAsFinished()
        assetWriter.finishWriting {
            completion()
        }
    }
}
