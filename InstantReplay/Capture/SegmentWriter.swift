import AVFoundation
import CoreMedia

final class SegmentWriter: @unchecked Sendable {
    nonisolated let fileURL: URL
    nonisolated let startTimestamp: CMTime

    private nonisolated(unsafe) let assetWriter: AVAssetWriter
    private nonisolated(unsafe) let videoInput: AVAssetWriterInput
    private nonisolated(unsafe) var isFinalized = false
    private nonisolated(unsafe) var frameCount = 0
    private nonisolated(unsafe) var appendFailCount = 0

    nonisolated init?(outputURL: URL, startTimestamp: CMTime, sourceFormatDescription: CMFormatDescription) {
        self.fileURL = outputURL
        self.startTimestamp = startTimestamp

        do {
            assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            debugLog("[SegmentWriter] failed to create AVAssetWriter: \(error)")
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

        guard assetWriter.canAdd(videoInput) else {
            debugLog("[SegmentWriter] canAdd(videoInput) returned false")
            return nil
        }
        assetWriter.add(videoInput)

        guard assetWriter.startWriting() else {
            debugLog("[SegmentWriter] startWriting failed: \(assetWriter.error?.localizedDescription ?? "unknown")")
            return nil
        }
        assetWriter.startSession(atSourceTime: startTimestamp)
        debugLog("[SegmentWriter] created \(outputURL.lastPathComponent), startTime=\(startTimestamp.seconds), dims=\(dimensions.width)x\(dimensions.height), status=\(assetWriter.status.rawValue)")
    }

    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        guard !isFinalized else { return }
        guard videoInput.isReadyForMoreMediaData else {
            appendFailCount += 1
            return
        }
        guard assetWriter.status == .writing else {
            if frameCount == 0 || (frameCount > 0 && appendFailCount == 0) {
                debugLog("[SegmentWriter] \(fileURL.lastPathComponent): writer status=\(assetWriter.status.rawValue), error=\(assetWriter.error?.localizedDescription ?? "none"), frames=\(frameCount)")
            }
            appendFailCount += 1
            return
        }
        let success = videoInput.append(sampleBuffer)
        if success {
            frameCount += 1
            if frameCount == 1 {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                debugLog("[SegmentWriter] \(fileURL.lastPathComponent): first frame appended, pts=\(pts.seconds)")
            }
        } else {
            appendFailCount += 1
            if appendFailCount <= 3 {
                debugLog("[SegmentWriter] \(fileURL.lastPathComponent): append failed, status=\(assetWriter.status.rawValue), error=\(assetWriter.error?.localizedDescription ?? "none"), frames=\(frameCount)")
            }
        }
    }

    nonisolated func finalize(completion: @escaping @Sendable () -> Void) {
        guard !isFinalized else {
            completion()
            return
        }
        isFinalized = true

        debugLog("[SegmentWriter] finalizing \(fileURL.lastPathComponent): \(frameCount) frames written, \(appendFailCount) failed appends, status=\(assetWriter.status.rawValue)")
        if assetWriter.status == .failed {
            debugLog("[SegmentWriter] writer already failed: \(assetWriter.error?.localizedDescription ?? "unknown")")
            completion()
            return
        }

        videoInput.markAsFinished()
        assetWriter.finishWriting { [self] in
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: self.fileURL.path)[.size] as? Int) ?? 0
            debugLog("[SegmentWriter] finalized \(self.fileURL.lastPathComponent): status=\(self.assetWriter.status.rawValue), error=\(self.assetWriter.error?.localizedDescription ?? "none"), fileSize=\(fileSize)")
            completion()
        }
    }
}
