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

        log("Left peaks: \(leftPeaks.count), Right peaks: \(rightPeaks.count)")

        // Merge all peaks and sort by timestamp
        var allPeaks = leftPeaks + rightPeaks
        allPeaks.sort { $0.timestamp < $1.timestamp }

        log("Total peaks: \(allPeaks.count)")
        for peak in allPeaks {
            log("  Peak at t=\(peak.timestamp), y=\(peak.y), foot=\(peak.foot)")
        }

        // Need at least 4 peaks for 4 steps
        guard allPeaks.count >= 4 else {
            log("Not enough peaks")
            return []
        }

        // Take the last 4 peaks (closest to takeoff - most reliable)
        let lastFourPeaks = Array(allPeaks.suffix(4))

        log("Selected peaks:")
        for peak in lastFourPeaks {
            log("  Selected: t=\(peak.timestamp), y=\(peak.y), foot=\(peak.foot)")
        }

        return lastFourPeaks.map { DetectedStep(timestamp: $0.timestamp, foot: $0.foot, ankleY: $0.y) }
    }

    private func findPeaks(in signal: [(timestamp: TimeInterval, y: CGFloat)], foot: String) -> [(timestamp: TimeInterval, y: CGFloat, foot: String)] {
        guard signal.count >= 3 else { return [] }

        var peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []

        for i in 1..<(signal.count - 1) {
            let prev = signal[i - 1].y
            let curr = signal[i].y
            let next = signal[i + 1].y

            // Local maximum in Y (foot plant - foot at lowest point = highest Y in screen coords)
            if curr > prev && curr >= next {
                peaks.append((timestamp: signal[i].timestamp, y: signal[i].y, foot: foot))
            }
        }

        return peaks
    }
}
