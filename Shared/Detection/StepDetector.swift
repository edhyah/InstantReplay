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

        // Merge and sort by timestamp
        var allPeaks = leftPeaks + rightPeaks
        allPeaks.sort { $0.timestamp < $1.timestamp }

        log("Left peaks: \(leftPeaks.count), Right peaks: \(rightPeaks.count), Total: \(allPeaks.count)")
        for peak in allPeaks {
            log("  Peak at t=\(peak.timestamp), y=\(peak.y), foot=\(peak.foot)")
        }

        // If we have fewer than 4 peaks, try to find more by relaxing the peak criteria
        if allPeaks.count < 4 {
            log("Not enough peaks with strict criteria, trying relaxed detection")
            allPeaks = findRelaxedPeaks(left: leftSignal, right: rightSignal)
            allPeaks.sort { $0.timestamp < $1.timestamp }
            log("Relaxed detection found \(allPeaks.count) peaks")
        }

        guard allPeaks.count >= 4 else {
            log("Not enough peaks even with relaxed detection")
            return []
        }

        // Select 4 well-distributed peaks working backwards from takeoff
        let selectedPeaks = selectWellDistributedPeaks(allPeaks, count: 4, minSpacing: 0.1)

        log("Selected peaks:")
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

    /// Find peaks with relaxed criteria for sparse data
    private func findRelaxedPeaks(left: [(timestamp: TimeInterval, y: CGFloat)], right: [(timestamp: TimeInterval, y: CGFloat)]) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)] {
        var allPoints: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []
        for p in left { allPoints.append((p.timestamp, p.y, "left")) }
        for p in right { allPoints.append((p.timestamp, p.y, "right")) }
        allPoints.sort { $0.timestamp < $1.timestamp }

        guard allPoints.count >= 3 else { return allPoints }

        var peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []

        // Find local maxima in Y (ignoring foot)
        for i in 1..<(allPoints.count - 1) {
            let prev = allPoints[i - 1].y
            let curr = allPoints[i].y
            let next = allPoints[i + 1].y

            if curr > prev && curr >= next {
                peaks.append(allPoints[i])
            }
        }

        // If still not enough, also include the endpoints if they look like peaks
        if peaks.count < 4 {
            if allPoints.first!.y >= (allPoints.count > 1 ? allPoints[1].y : 0) {
                peaks.insert(allPoints.first!, at: 0)
            }
            if let last = allPoints.last, last.y >= (allPoints.count > 1 ? allPoints[allPoints.count - 2].y : 0) {
                peaks.append(last)
            }
        }

        return peaks
    }

    /// Select n well-distributed peaks, preferring those closest to takeoff
    private func selectWellDistributedPeaks(_ peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)], count: Int, minSpacing: TimeInterval) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)] {
        guard peaks.count >= count else { return peaks }

        // Sort by timestamp descending (latest first)
        let sortedPeaks = peaks.sorted { $0.timestamp > $1.timestamp }

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

        // Return in chronological order (earliest first)
        return selected.reversed()
    }
}
