import CoreGraphics
import Foundation
import Vision

struct DetectedStep: Sendable {
    let timestamp: TimeInterval
    let foot: String  // "left", "right", or "unknown"
    let ankleY: CGFloat
}

final class StepDetector: Sendable {
    private nonisolated(unsafe) var frameData: [(timestamp: TimeInterval, leftAnkleY: CGFloat?, rightAnkleY: CGFloat?)] = []
    private nonisolated(unsafe) var debugLog: [String] = []

    private func log(_ message: String) {
        debugLog.append(message)
    }

    func writeDebugLog(to path: String) {
        let content = debugLog.joined(separator: "\n")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func recordFrame(timestamp: TimeInterval, jointPoints: [VNHumanBodyPoseObservation.JointName: CGPoint]) {
        let leftAnkleY = jointPoints[.leftAnkle]?.y
        let rightAnkleY = jointPoints[.rightAnkle]?.y
        frameData.append((timestamp: timestamp, leftAnkleY: leftAnkleY, rightAnkleY: rightAnkleY))
    }

    func reset() {
        frameData.removeAll()
    }

    /// Detect steps between approachStart and takeoff
    /// Returns array of 4 steps: first, second, orientation, plant
    func detectSteps(approachStart: TimeInterval, takeoff: TimeInterval) -> [DetectedStep] {
        debugLog.removeAll() // Clear log for each detection
        log("detectSteps called for \(approachStart) to \(takeoff)")
        log("Total frame data count: \(frameData.count)")

        // Filter frames within the approach window
        let approachFrames = frameData.filter { $0.timestamp >= approachStart && $0.timestamp <= takeoff }
        log("Approach frames count: \(approachFrames.count)")

        guard approachFrames.count >= 4 else {
            log("Not enough frames")
            return []
        }

        // Build separate signals for left and right ankles
        var leftSignal: [(timestamp: TimeInterval, y: CGFloat)] = []
        var rightSignal: [(timestamp: TimeInterval, y: CGFloat)] = []

        for frame in approachFrames {
            if let leftY = frame.leftAnkleY {
                leftSignal.append((timestamp: frame.timestamp, y: leftY))
            }
            if let rightY = frame.rightAnkleY {
                rightSignal.append((timestamp: frame.timestamp, y: rightY))
            }
        }

        log("Left signal count: \(leftSignal.count), Right signal count: \(rightSignal.count)")

        // Find peaks in each signal
        let leftPeaks = findPeaks(in: leftSignal, foot: "left")
        let rightPeaks = findPeaks(in: rightSignal, foot: "right")

        log("Left peaks: \(leftPeaks.count), Right peaks: \(rightPeaks.count)")
        for peak in (leftPeaks + rightPeaks).sorted(by: { $0.timestamp < $1.timestamp }) {
            log("  Peak at t=\(peak.timestamp), y=\(peak.y), foot=\(peak.foot)")
        }

        // Try to find 4 steps with the expected alternating pattern: right, left, right, left
        // Use target timing based on typical volleyball approach
        if let sequence = findBestAlternatingSequence(rightPeaks: rightPeaks, leftPeaks: leftPeaks, takeoff: takeoff) {
            log("Found alternating sequence")
            for peak in sequence {
                log("  Selected: t=\(peak.timestamp), y=\(peak.y), foot=\(peak.foot)")
            }
            return sequence.map { DetectedStep(timestamp: $0.timestamp, foot: $0.foot, ankleY: $0.y) }
        }

        // Fallback: merge all peaks and select 4 well-distributed ones
        log("Could not find alternating pattern, using fallback")
        var allPeaks = leftPeaks + rightPeaks
        allPeaks.sort { $0.timestamp < $1.timestamp }

        guard allPeaks.count >= 4 else {
            log("Not enough peaks")
            return []
        }

        let selectedPeaks = selectWellDistributedPeaks(allPeaks, count: 4, minSpacing: 0.1)

        log("Fallback selected peaks:")
        for peak in selectedPeaks {
            log("  Selected: t=\(peak.timestamp), y=\(peak.y), foot=\(peak.foot)")
        }

        return selectedPeaks.map { DetectedStep(timestamp: $0.timestamp, foot: $0.foot, ankleY: $0.y) }
    }

    private func findPeaks(in signal: [(timestamp: TimeInterval, y: CGFloat)], foot: String) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)] {
        guard signal.count >= 3 else { return [] }

        var peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []

        for i in 1..<(signal.count - 1) {
            let prev = signal[i - 1].y
            let curr = signal[i].y
            let next = signal[i + 1].y

            if curr > prev && curr >= next {
                peaks.append((timestamp: signal[i].timestamp, y: signal[i].y, foot: foot))
            }
        }

        return peaks
    }

    /// Find 4 steps with alternating pattern: right, left, right, left
    /// Uses target timing to find peaks closest to expected positions
    private func findBestAlternatingSequence(
        rightPeaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)],
        leftPeaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)],
        takeoff: TimeInterval
    ) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)]? {
        guard !rightPeaks.isEmpty && !leftPeaks.isEmpty else { return nil }

        // Typical volleyball approach timing (from takeoff, going backwards):
        // plant: 0-0.2s before takeoff
        // orientation: 0.2-0.5s before takeoff
        // second: 0.6-1.0s before takeoff
        // first: 1.0-1.5s before takeoff

        let sortedLeft = leftPeaks.sorted { $0.timestamp < $1.timestamp }
        let sortedRight = rightPeaks.sorted { $0.timestamp < $1.timestamp }

        // Find plant (left, closest to takeoff, within 0.3s)
        guard let plant = sortedLeft.reversed().first(where: { takeoff - $0.timestamp <= 0.3 && takeoff - $0.timestamp >= 0 }) else {
            log("No plant found within 0.3s of takeoff")
            return nil
        }

        // Find orientation (right, before plant, with minimum separation)
        // Must be at least 0.05s before plant to avoid same-timestamp issues
        let orientationTarget = plant.timestamp - 0.3
        guard let orientation = findClosestPeak(in: sortedRight, target: orientationTarget, maxDelta: 0.3, before: plant.timestamp - 0.05) else {
            log("No orientation found")
            return nil
        }

        // Find second (left, before orientation)
        let secondTarget = orientation.timestamp - 0.5
        guard let second = findClosestPeak(in: sortedLeft, target: secondTarget, maxDelta: 0.4, before: orientation.timestamp - 0.05) else {
            log("No second found")
            return nil
        }

        // Find first (right, before second)
        let firstTarget = second.timestamp - 0.5
        guard let first = findClosestPeak(in: sortedRight, target: firstTarget, maxDelta: 0.5, before: second.timestamp - 0.05) else {
            log("No first found")
            return nil
        }

        return [first, second, orientation, plant]
    }

    /// Find the peak closest to target timestamp within maxDelta, optionally before a given time
    private func findClosestPeak(
        in peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)],
        target: TimeInterval,
        maxDelta: TimeInterval,
        before: TimeInterval? = nil
    ) -> (timestamp: TimeInterval, y: CGFloat, foot: String)? {
        var candidates = peaks
        if let beforeTime = before {
            candidates = candidates.filter { $0.timestamp < beforeTime }
        }

        let validPeaks = candidates.filter { abs($0.timestamp - target) <= maxDelta }
        return validPeaks.min(by: { abs($0.timestamp - target) < abs($1.timestamp - target) })
    }

    /// Select n well-distributed peaks, preferring those closest to takeoff
    private func selectWellDistributedPeaks(_ peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)], count: Int, minSpacing: TimeInterval) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)] {
        guard peaks.count >= count else { return peaks }

        // Deduplicate peaks at the same timestamp (keep one with higher Y)
        var uniquePeaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []
        let sortedByTime = peaks.sorted { $0.timestamp < $1.timestamp }
        for peak in sortedByTime {
            if let lastPeak = uniquePeaks.last, lastPeak.timestamp == peak.timestamp {
                // Same timestamp - keep the one with higher Y (more prominent foot plant)
                if peak.y > lastPeak.y {
                    uniquePeaks[uniquePeaks.count - 1] = peak
                }
            } else {
                uniquePeaks.append(peak)
            }
        }

        guard uniquePeaks.count >= count else { return uniquePeaks }

        let sortedPeaks = uniquePeaks.sorted { $0.timestamp > $1.timestamp }

        var selected: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []

        for peak in sortedPeaks {
            if selected.isEmpty {
                selected.append(peak)
            } else if let lastSelected = selected.last, peak.timestamp < lastSelected.timestamp - minSpacing {
                selected.append(peak)
            }

            if selected.count == count {
                break
            }
        }

        return selected.reversed()
    }
}
