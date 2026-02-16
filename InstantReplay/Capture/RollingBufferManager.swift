import AVFoundation
import CoreMedia
import Foundation

struct SegmentInfo: Sendable {
    let fileURL: URL
    let startTimestamp: CMTime
    var endTimestamp: CMTime?
}

final class RollingBufferManager: @unchecked Sendable {
    private let writerQueue = DispatchQueue(label: "com.edwardahn.InstantReplay.fileWriter", qos: .utility)

    private nonisolated(unsafe) var activeWriter: SegmentWriter?
    private nonisolated(unsafe) var retiringWriter: SegmentWriter?
    private nonisolated(unsafe) var sourceFormatDescription: CMFormatDescription?

    private nonisolated(unsafe) var segmentStartTime: CMTime = .zero
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

    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        writerQueue.async { [self] in
            self.handleAppend(buffer)
        }
    }

    nonisolated func stop() {
        writerQueue.async { [self] in
            self.finalizeAll()
        }
    }

    nonisolated func reset() {
        writerQueue.async { [self] in
            self.finalizeAll()
            self.cleanupAllSegmentFiles()

            self.segmentsLock.lock()
            self._segments.removeAll()
            self.segmentsLock.unlock()

            self.sourceFormatDescription = nil
            self.segmentIndex = 0
        }
    }

    // MARK: - Private (called on writerQueue)

    private nonisolated func handleAppend(_ sampleBuffer: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        // Capture format description from the first buffer
        if sourceFormatDescription == nil {
            sourceFormatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        }

        // Start the first writer if none exists
        if activeWriter == nil {
            startNewSegment(at: presentationTime)
        }

        guard let active = activeWriter else { return }

        // Check if it's time to rotate: start a new overlapping writer
        let elapsed = CMTimeGetSeconds(presentationTime) - CMTimeGetSeconds(segmentStartTime)
        let rotationPoint = CaptureConstants.segmentRotationInterval - CaptureConstants.segmentOverlapDuration

        if elapsed >= rotationPoint && retiringWriter == nil {
            // Begin overlap: start new writer, keep old one alive
            retiringWriter = active
            startNewSegment(at: presentationTime)
        }

        // Finalize the retiring writer after overlap period
        if let retiring = retiringWriter {
            let retireElapsed = CMTimeGetSeconds(presentationTime) - CMTimeGetSeconds(segmentStartTime)
            if retireElapsed >= CaptureConstants.segmentOverlapDuration {
                let retiringURL = retiring.fileURL
                let retiringStart = retiring.startTimestamp
                retiring.finalize { [weak self] in
                    self?.writerQueue.async {
                        self?.onSegmentFinalized(url: retiringURL, startTimestamp: retiringStart, endTimestamp: presentationTime)
                    }
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

        // Keep at most 3 segments: the active one, the previous finalized one,
        // and potentially one more that a replay might reference.
        // Delete anything older.
        guard currentSegments.count > 3 else { return }

        let toRemoveCount = currentSegments.count - 3
        let toRemove = Array(currentSegments.prefix(toRemoveCount))

        replayLock.lock()
        let referenced = replayReferencedURLs
        replayLock.unlock()

        var removedURLs: [URL] = []
        for segment in toRemove {
            if referenced.contains(segment.fileURL) {
                continue // defer deletion — replay still using this file
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
