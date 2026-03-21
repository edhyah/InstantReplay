@preconcurrency import AVFoundation
import CoreMedia

struct ClipAsset: @unchecked Sendable {
    let asset: AVAsset
    let timeRange: CMTimeRange
    let referencedURLs: Set<URL>
}

final class ClipExtractor: @unchecked Sendable {
    private let rollingBuffer: RollingBufferManager

    nonisolated init(rollingBuffer: RollingBufferManager) {
        self.rollingBuffer = rollingBuffer
    }

    /// Extracts a clip around the landing timestamp from the rolling buffer segments.
    /// Waits for post-landing frames to flush, forces a segment rotation so the file
    /// is readable, then builds a composition spanning [landingTime - preRoll, landingTime + postRoll].
    nonisolated func extractClip(
        landingTimestamp: CMTime,
        completion: @escaping @Sendable (ClipAsset?) -> Void
    ) {
        let waitTime = CaptureConstants.clipPostLandingWait
        debugLog("[ClipExtractor] waiting \(waitTime)s for post-landing frames")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitTime) { [self] in
            debugLog("[ClipExtractor] forcing segment rotation")
            self.rollingBuffer.forceRotation {
                debugLog("[ClipExtractor] rotation complete, building clip")
                let result = self.buildClip(landingTimestamp: landingTimestamp)
                completion(result)
            }
        }
    }

    private nonisolated func buildClip(landingTimestamp: CMTime) -> ClipAsset? {
        let preRoll = CaptureConstants.clipPreRollDuration
        let postRoll = CaptureConstants.clipPostRollDuration

        let idealClipStart = CMTimeSubtract(landingTimestamp, CMTimeMakeWithSeconds(preRoll, preferredTimescale: landingTimestamp.timescale))
        let clipEnd = CMTimeAdd(landingTimestamp, CMTimeMakeWithSeconds(postRoll, preferredTimescale: landingTimestamp.timescale))

        let segments = rollingBuffer.segments
        debugLog("[ClipExtractor] idealClipStart=\(idealClipStart.seconds), clipEnd=\(clipEnd.seconds)")
        debugLog("[ClipExtractor] total segments: \(segments.count)")
        for (i, seg) in segments.enumerated() {
            let endStr = seg.endTimestamp.map { String($0.seconds) } ?? "nil(active)"
            debugLog("[ClipExtractor]   seg[\(i)]: start=\(seg.startTimestamp.seconds), end=\(endStr), file=\(seg.fileURL.lastPathComponent)")
        }

        // Only use finalized segments (endTimestamp != nil) — active segments aren't readable
        let relevantSegments = segments.filter { segment in
            guard let segEnd = segment.endTimestamp else { return false }
            let segStart = segment.startTimestamp
            return CMTimeCompare(segStart, clipEnd) < 0 && CMTimeCompare(segEnd, idealClipStart) > 0
        }

        debugLog("[ClipExtractor] relevant finalized segments: \(relevantSegments.count)")
        guard !relevantSegments.isEmpty else {
            debugLog("[ClipExtractor] no relevant segments found, returning nil")
            return nil
        }

        // Clamp clip start to earliest available segment (graceful degradation for short pre-roll)
        let earliestStart = relevantSegments.map { $0.startTimestamp }.min()!
        let clipStart = CMTimeMaximum(idealClipStart, earliestStart)

        let referencedURLs = Set(relevantSegments.map { $0.fileURL })

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            return nil
        }

        var insertionTime = CMTime.zero

        for segment in relevantSegments {
            let asset = AVURLAsset(url: segment.fileURL)
            let tracks = asset.tracks(withMediaType: .video)
            debugLog("[ClipExtractor] segment \(segment.fileURL.lastPathComponent): \(tracks.count) video tracks, asset duration=\(asset.duration.seconds)")
            guard let assetTrack = tracks.first else {
                debugLog("[ClipExtractor]   skipping — no video track")
                continue
            }

            let segStart = segment.startTimestamp
            let segEnd = segment.endTimestamp!

            let overlapStart = CMTimeMaximum(clipStart, segStart)
            let overlapEnd = CMTimeMinimum(clipEnd, segEnd)

            guard CMTimeCompare(overlapStart, overlapEnd) < 0 else { continue }

            // Convert to segment-local time
            let localStart = CMTimeSubtract(overlapStart, segStart)
            let localEnd = CMTimeSubtract(overlapEnd, segStart)
            let localRange = CMTimeRangeMake(start: localStart, duration: CMTimeSubtract(localEnd, localStart))

            debugLog("[ClipExtractor]   localRange: start=\(localRange.start.seconds), dur=\(localRange.duration.seconds)")
            do {
                try compositionTrack.insertTimeRange(localRange, of: assetTrack, at: insertionTime)
                insertionTime = CMTimeAdd(insertionTime, localRange.duration)
                debugLog("[ClipExtractor]   inserted, total duration so far=\(insertionTime.seconds)")
            } catch {
                debugLog("[ClipExtractor]   insertTimeRange failed: \(error)")
                continue
            }
        }

        guard CMTimeGetSeconds(insertionTime) >= 0.5 else {
            debugLog("[ClipExtractor] clip too short (\(CMTimeGetSeconds(insertionTime))s), returning nil")
            return nil
        }

        let timeRange = CMTimeRangeMake(start: .zero, duration: insertionTime)
        return ClipAsset(asset: composition, timeRange: timeRange, referencedURLs: referencedURLs)
    }
}
