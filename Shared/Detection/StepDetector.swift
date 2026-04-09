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

    #if DEBUG
    func writeDebugLog(to path: String) {
        let content = debugLog.joined(separator: "\n")
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
    #endif

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

        // Merge all peaks - side-view camera makes left/right ankle distinction unreliable
        var allPeaks = leftPeaks + rightPeaks
        allPeaks.sort { $0.timestamp < $1.timestamp }

        guard allPeaks.count >= 4 else {
            log("Not enough peaks")
            return []
        }

        // Find best sequence using timing-based approach
        if let sequence = findBestTimedSequence(peaks: allPeaks, takeoff: takeoff) {
            log("Found best-timed sequence")
            // Always assign expected foot pattern: right, left, right, left
            let footPattern = ["right", "left", "right", "left"]
            var result: [DetectedStep] = []
            for (i, peak) in sequence.enumerated() {
                log("  Selected: t=\(peak.timestamp), y=\(peak.y), assigned foot=\(footPattern[i])")
                result.append(DetectedStep(timestamp: peak.timestamp, foot: footPattern[i], ankleY: peak.y))
            }
            return result
        }

        // Fallback: select 4 well-distributed peaks
        log("Using fallback selection")
        let selectedPeaks = selectWellDistributedPeaks(allPeaks, count: 4, minSpacing: 0.1)

        // Always assign expected foot pattern: right, left, right, left
        let footPattern = ["right", "left", "right", "left"]
        var result: [DetectedStep] = []
        for (i, peak) in selectedPeaks.enumerated() {
            log("  Fallback selected: t=\(peak.timestamp), y=\(peak.y), assigned foot=\(footPattern[i])")
            result.append(DetectedStep(timestamp: peak.timestamp, foot: footPattern[i], ankleY: peak.y))
        }
        return result
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

    /// Find 4 steps using timing-based approach, ignoring left/right distinction
    private func findBestTimedSequence(
        peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)],
        takeoff: TimeInterval
    ) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)]? {
        // Find plant: latest peak within 0.3s of takeoff
        let plantCandidates = peaks.filter { takeoff - $0.timestamp <= 0.3 && takeoff - $0.timestamp >= 0 }
        guard let plant = plantCandidates.max(by: { $0.timestamp < $1.timestamp }) else {
            log("No plant found within 0.3s of takeoff")
            return nil
        }
        log("Found plant at \(plant.timestamp)")

        // Get peaks between start and plant for finding first, second, orientation
        let middlePeaks = peaks.filter {
            $0.timestamp < plant.timestamp - 0.1 &&
            $0.timestamp > takeoff - 2.0  // reasonable approach start
        }

        guard middlePeaks.count >= 3 else {
            log("Not enough middle peaks")
            return nil
        }

        // Find first step candidates
        let firstCandidates = middlePeaks.filter {
            $0.timestamp < plant.timestamp - 0.7 &&  // at least 0.7s before plant
            $0.timestamp > plant.timestamp - 1.5  // at most 1.5s before plant
        }

        guard !firstCandidates.isEmpty else {
            log("No first step candidates")
            return nil
        }

        // Try each first candidate and find best sequence
        var bestSequence: [(timestamp: TimeInterval, y: CGFloat, foot: String)]?
        var bestScore = Double.infinity

        for first in firstCandidates {
            if let seq = tryBuildSequence(first: first, plant: plant, peaks: middlePeaks) {
                let score = scoreSequence(seq, takeoff: takeoff)
                log("First=\(first.timestamp): score=\(score)")
                if score < bestScore {
                    bestScore = score
                    bestSequence = seq
                }
            }
        }

        return bestSequence
    }

    /// Try to build a sequence from first and plant, finding second and orientation in between
    private func tryBuildSequence(
        first: (timestamp: TimeInterval, y: CGFloat, foot: String),
        plant: (timestamp: TimeInterval, y: CGFloat, foot: String),
        peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)]
    ) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)]? {
        // Get peaks between first and plant
        let betweenPeaks = peaks.filter {
            $0.timestamp > first.timestamp + 0.15 &&
            $0.timestamp < plant.timestamp - 0.1
        }

        guard betweenPeaks.count >= 2 else { return nil }

        // Divide the first-to-plant span: target 35% and 70% marks
        let span = plant.timestamp - first.timestamp
        let secondTarget = first.timestamp + span * 0.38
        let orientationTarget = first.timestamp + span * 0.72

        // Find second: peak closest to secondTarget
        guard let second = betweenPeaks.min(by: {
            abs($0.timestamp - secondTarget) < abs($1.timestamp - secondTarget)
        }) else {
            return nil
        }

        // Find orientation: peak closest to orientationTarget, after second
        let orientationCandidates = betweenPeaks.filter { $0.timestamp > second.timestamp + 0.1 }
        guard let orientation = orientationCandidates.min(by: {
            abs($0.timestamp - orientationTarget) < abs($1.timestamp - orientationTarget)
        }) else {
            return nil
        }

        return [first, second, orientation, plant]
    }

    /// Score a sequence - lower is better
    private func scoreSequence(_ sequence: [(timestamp: TimeInterval, y: CGFloat, foot: String)], takeoff: TimeInterval) -> Double {
        guard sequence.count == 4 else { return Double.infinity }

        let first = sequence[0].timestamp
        let second = sequence[1].timestamp
        let orientation = sequence[2].timestamp
        let plant = sequence[3].timestamp

        // Penalize sequences with intervals outside reasonable ranges
        var score = 0.0
        let i1 = second - first
        let i2 = orientation - second
        let i3 = plant - orientation

        // first to second: 0.3-0.6s acceptable
        if i1 < 0.25 || i1 > 0.65 { score += 1.0 }
        // second to orientation: 0.2-0.6s acceptable
        if i2 < 0.15 || i2 > 0.65 { score += 1.0 }
        // orientation to plant: 0.1-0.5s acceptable
        if i3 < 0.1 || i3 > 0.55 { score += 1.0 }

        // Only penalize if total span is outside wide acceptable range (0.85-1.5s)
        let totalSpan = plant - first
        if totalSpan < 0.85 || totalSpan > 1.5 { score += 0.5 }

        return score
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
