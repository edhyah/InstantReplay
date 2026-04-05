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

        // Combine ankle signals - use whichever ankle is lower (higher Y)
        var combinedSignal: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []
        for frame in approachFrames {
            let leftY = frame.leftAnkleY ?? 0
            let rightY = frame.rightAnkleY ?? 0

            if leftY > rightY && frame.leftAnkleY != nil {
                combinedSignal.append((timestamp: frame.timestamp, y: leftY, foot: "left"))
            } else if frame.rightAnkleY != nil {
                combinedSignal.append((timestamp: frame.timestamp, y: rightY, foot: "right"))
            }
        }

        log("Combined signal count: \(combinedSignal.count)")
        guard combinedSignal.count >= 4 else {
            log("Not enough combined signal")
            return []
        }

        // Find local maxima in Y (foot plants - foot is at lowest point on screen = highest Y)
        var peaks: [(timestamp: TimeInterval, y: CGFloat, foot: String)] = []

        for i in 1..<(combinedSignal.count - 1) {
            let prev = combinedSignal[i - 1].y
            let curr = combinedSignal[i].y
            let next = combinedSignal[i + 1].y

            // Local maximum in Y (foot plant)
            if curr > prev && curr >= next {
                peaks.append(combinedSignal[i])
            }
        }

        log("Found \(peaks.count) peaks")
        for peak in peaks {
            log("  Peak at t=\(peak.timestamp), y=\(peak.y), foot=\(peak.foot)")
        }

        // Need at least 4 peaks for 4 steps
        guard peaks.count >= 4 else {
            log("Not enough peaks")
            return []
        }

        // Take the last 4 peaks before takeoff (most reliable)
        let lastFourPeaks = Array(peaks.suffix(4))

        return lastFourPeaks.map { DetectedStep(timestamp: $0.timestamp, foot: $0.foot, ankleY: $0.y) }
    }
}
