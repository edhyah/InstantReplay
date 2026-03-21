import AVFoundation
import CoreMedia
import Foundation

struct SegmentInfo: Sendable {
    let fileURL: URL
    let startTimestamp: CMTime
    var endTimestamp: CMTime?
}

final class RollingBufferManager: @unchecked Sendable {
    // Lock protects all mutable writer state. Held briefly during append (fast path)
    // and during rotation/finalization (slow path, rare).
    private let lock = NSLock()

    private nonisolated(unsafe) var activeWriter: SegmentWriter?
    private nonisolated(unsafe) var retiringWriter: SegmentWriter?
    private nonisolated(unsafe) var sourceFormatDescription: CMFormatDescription?

    private nonisolated(unsafe) var segmentStartTime: CMTime = .zero
    private nonisolated(unsafe) var lastPresentationTime: CMTime = .zero
    private nonisolated(unsafe) var segmentIndex = 0

    private nonisolated(unsafe) var _segments: [SegmentInfo] = []
    private let segmentsLock = NSLock()

    private nonisolated(unsafe) var replayReferencedURLs: Set<URL> = []
    private let replayLock = NSLock()

    private let segmentDirectory: URL = {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("InstantReplaySegments", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }()

    nonisolated init() {}

    nonisolated var segments: [SegmentInfo] {
        segmentsLock.lock()
        defer { segmentsLock.unlock() }
        return _segments
    }

    nonisolated func markReplayReference(_ urls: Set<URL>) {
        replayLock.lock()
        replayReferencedURLs = urls
        replayLock.unlock()
    }

    nonisolated func clearReplayReference() {
        replayLock.lock()
        replayReferencedURLs.removeAll()
        replayLock.unlock()
    }

    /// Forces the active segment to finalize. Blocks until finalization is complete
    /// so the segment file is readable.
    nonisolated func forceRotation(completion: @escaping @Sendable () -> Void) {
        lock.lock()

        guard let active = self.activeWriter, self.sourceFormatDescription != nil else {
            debugLog("[RollingBuffer] forceRotation: no active writer or format desc, skipping")
            lock.unlock()
            completion()
            return
        }
        debugLog("[RollingBuffer] forceRotation: active=\(active.fileURL.lastPathComponent), lastPTS=\(self.lastPresentationTime.seconds)")

        // If there's already a retiring writer, finalize it first
        if let retiring = self.retiringWriter {
            let url = retiring.fileURL
            let start = retiring.startTimestamp
            self.retiringWriter = nil
            lock.unlock()

            let group = DispatchGroup()
            group.enter()
            retiring.finalize {
                group.leave()
            }
            group.wait()
            onSegmentFinalized(url: url, startTimestamp: start, endTimestamp: active.startTimestamp)

            lock.lock()
        }

        // Swap active writer out and start a new segment
        let oldWriter = active
        let oldURL = oldWriter.fileURL
        let oldStart = oldWriter.startTimestamp
        let endTime = self.lastPresentationTime

        self.startNewSegment(at: endTime)
        lock.unlock()

        debugLog("[RollingBuffer] forceRotation: finalizing \(oldURL.lastPathComponent), start=\(oldStart.seconds), end=\(endTime.seconds)")

        let group = DispatchGroup()
        group.enter()
        oldWriter.finalize {
            group.leave()
        }
        group.wait()

        debugLog("[RollingBuffer] forceRotation: finalization complete for \(oldURL.lastPathComponent)")
        onSegmentFinalized(url: oldURL, startTimestamp: oldStart, endTimestamp: endTime)
        completion()
    }

    /// Appends a sample buffer to the active writer(s). Called synchronously on the
    /// camera queue so the pixel buffer is released immediately after encoding.
    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        handleAppend(sampleBuffer)
        lock.unlock()
    }

    nonisolated func stop() {
        lock.lock()
        finalizeAll()
        lock.unlock()
    }

    nonisolated func reset() {
        lock.lock()
        finalizeAll()
        cleanupAllSegmentFiles()

        segmentsLock.lock()
        _segments.removeAll()
        segmentsLock.unlock()

        sourceFormatDescription = nil
        segmentIndex = 0
        lastPresentationTime = .zero
        lock.unlock()
    }

    // MARK: - Private (caller must hold lock)

    private nonisolated func handleAppend(_ sampleBuffer: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        lastPresentationTime = presentationTime

        // Capture format description from the first buffer
        if sourceFormatDescription == nil {
            sourceFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        }

        // Start the first writer if none exists
        if activeWriter == nil {
            startNewSegment(at: presentationTime)
        }

        guard let _ = activeWriter else { return }

        // Check if it's time to rotate: start a new overlapping writer
        let elapsed = CMTimeGetSeconds(presentationTime) - CMTimeGetSeconds(segmentStartTime)
        let rotationPoint = CaptureConstants.segmentRotationInterval - CaptureConstants.segmentOverlapDuration

        if elapsed >= rotationPoint && retiringWriter == nil {
            // Begin overlap: start new writer, keep old one alive
            retiringWriter = activeWriter
            startNewSegment(at: presentationTime)
        }

        // Finalize the retiring writer after overlap period
        if let retiring = retiringWriter {
            let retireElapsed = CMTimeGetSeconds(presentationTime) - CMTimeGetSeconds(segmentStartTime)
            if retireElapsed >= CaptureConstants.segmentOverlapDuration {
                let retiringURL = retiring.fileURL
                let retiringStart = retiring.startTimestamp
                let finalizeTime = presentationTime
                retiring.finalize { [weak self] in
                    self?.onSegmentFinalized(url: retiringURL, startTimestamp: retiringStart, endTimestamp: finalizeTime)
                }
                self.retiringWriter = nil
            } else {
                // During overlap, write to both
                retiring.append(sampleBuffer)
            }
        }

        // Always write to the active writer
        activeWriter?.append(sampleBuffer)
    }

    private nonisolated func startNewSegment(at timestamp: CMTime) {
        guard let formatDesc = sourceFormatDescription else { return }

        let fileName = "segment_\(segmentIndex).mp4"
        let fileURL = segmentDirectory.appendingPathComponent(fileName)

        // Remove any existing file at this path
        try? FileManager.default.removeItem(at: fileURL)

        guard let writer = SegmentWriter(outputURL: fileURL, startTimestamp: timestamp, sourceFormatDescription: formatDesc) else {
            return
        }

        activeWriter = writer
        segmentStartTime = timestamp
        segmentIndex += 1

        segmentsLock.lock()
        _segments.append(SegmentInfo(fileURL: fileURL, startTimestamp: timestamp, endTimestamp: nil))
        segmentsLock.unlock()
    }

    private nonisolated func onSegmentFinalized(url: URL, startTimestamp: CMTime, endTimestamp: CMTime) {
        segmentsLock.lock()
        if let idx = _segments.firstIndex(where: { $0.fileURL == url }) {
            _segments[idx].endTimestamp = endTimestamp
        }
        segmentsLock.unlock()

        pruneOldSegments()
    }

    private nonisolated func pruneOldSegments() {
        segmentsLock.lock()
        let currentSegments = _segments
        segmentsLock.unlock()

        guard currentSegments.count > 3 else { return }

        let toRemoveCount = currentSegments.count - 3
        let toRemove = Array(currentSegments.prefix(toRemoveCount))

        replayLock.lock()
        let referenced = replayReferencedURLs
        replayLock.unlock()

        var removedURLs: [URL] = []
        for segment in toRemove {
            if referenced.contains(segment.fileURL) {
                continue
            }
            try? FileManager.default.removeItem(at: segment.fileURL)
            removedURLs.append(segment.fileURL)
        }

        if !removedURLs.isEmpty {
            segmentsLock.lock()
            _segments.removeAll { seg in removedURLs.contains(seg.fileURL) }
            segmentsLock.unlock()
        }
    }

    private nonisolated func finalizeAll() {
        let group = DispatchGroup()

        if let active = activeWriter {
            group.enter()
            let url = active.fileURL
            active.finalize { [weak self] in
                self?.segmentsLock.lock()
                if let idx = self?._segments.firstIndex(where: { $0.fileURL == url }) {
                    self?._segments[idx].endTimestamp = .zero
                }
                self?.segmentsLock.unlock()
                group.leave()
            }
            activeWriter = nil
        }

        if let retiring = retiringWriter {
            group.enter()
            let url = retiring.fileURL
            retiring.finalize { [weak self] in
                self?.segmentsLock.lock()
                if let idx = self?._segments.firstIndex(where: { $0.fileURL == url }) {
                    self?._segments[idx].endTimestamp = .zero
                }
                self?.segmentsLock.unlock()
                group.leave()
            }
            retiringWriter = nil
        }

        group.wait()
    }

    private nonisolated func cleanupAllSegmentFiles() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: segmentDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }
}
