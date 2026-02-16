import CoreGraphics
import CoreMedia
import QuartzCore

enum ApproachState: String, Sendable {
    case idle = "IDLE"
    case approaching = "APPROACHING"
    case ascending = "ASCENDING"
    case descending = "DESCENDING"
}

struct StateMachineThresholds: Sendable {
    let approachHorizontalVelocity: CGFloat = 0.20
    let approachSustainedFrames: Int = 4
    let approachMinDuration: TimeInterval = 0.3
    let ascendingVerticalVelocity: CGFloat = -0.25 // negative = upward in top-left origin coords
    let descendingVerticalVelocity: CGFloat = 0.10 // positive = downward
    let landingVerticalMagnitude: CGFloat = 0.08
    let timeoutDuration: TimeInterval = 3.0
}

struct StateMachineDebugInfo: Sendable {
    let state: ApproachState
    let thresholds: StateMachineThresholds
    let poseFramesProcessed: Int
    let poseStartTime: CFTimeInterval
}

final class ApproachDetectorStateMachine: Sendable {
    let thresholds = StateMachineThresholds()

    private nonisolated(unsafe) var state: ApproachState = .idle
    private nonisolated(unsafe) var stateEntryTime: CFTimeInterval = 0
    private nonisolated(unsafe) var approachFrameCount: Int = 0
    private nonisolated(unsafe) var dominantMoverID: Int? = nil
    private nonisolated(unsafe) var poseFramesProcessed: Int = 0
    private nonisolated(unsafe) var poseStartTime: CFTimeInterval = 0

    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?

    func step(dominantMover: TrackedBody?, timestamp: CMTime) -> StateMachineDebugInfo {
        let now = CACurrentMediaTime()

        // Track pose FPS
        if poseStartTime == 0 {
            poseStartTime = now
        }
        poseFramesProcessed += 1

        // If no dominant mover and we're mid-sequence, reset
        guard let mover = dominantMover else {
            if state != .idle {
                resetToIdle(now: now)
            }
            return makeDebugInfo()
        }

        // If the dominant mover changed while mid-sequence, reset
        if let prevID = dominantMoverID, prevID != mover.id, state != .idle {
            resetToIdle(now: now)
        }
        dominantMoverID = mover.id

        // Timeout: 3 seconds in any non-idle state without progression
        if state != .idle && (now - stateEntryTime) > thresholds.timeoutDuration {
            resetToIdle(now: now)
        }

        let absHVel = abs(mover.horizontalVelocity)
        let vVel = mover.verticalVelocity // positive = downward in screen coords

        switch state {
        case .idle:
            if absHVel > thresholds.approachHorizontalVelocity {
                approachFrameCount += 1
                if approachFrameCount >= thresholds.approachSustainedFrames {
                    transition(to: .approaching, now: now)
                }
            } else {
                approachFrameCount = 0
            }

        case .approaching:
            // Check for vertical takeoff: upward = negative vertical velocity in top-left coords
            let timeInApproaching = now - stateEntryTime
            if timeInApproaching >= thresholds.approachMinDuration
                && vVel < -thresholds.ascendingVerticalVelocity // going up (negative)
                && absHVel > 0 {
                transition(to: .ascending, now: now)
            }
            // If horizontal velocity drops entirely, keep in approaching (timeout will catch stalls)

        case .ascending:
            // Vertical velocity reversal — now moving downward past threshold
            if vVel > thresholds.descendingVerticalVelocity {
                transition(to: .descending, now: now)
            }

        case .descending:
            // Vertical velocity magnitude drops below threshold — landed
            if abs(vVel) < thresholds.landingVerticalMagnitude {
                // Emit landing event
                onMovementDetected?(MovementDetectionEvent(landingTimestamp: timestamp))
                resetToIdle(now: now)
            }
        }

        return makeDebugInfo()
    }

    func reset() {
        state = .idle
        stateEntryTime = 0
        approachFrameCount = 0
        dominantMoverID = nil
        poseFramesProcessed = 0
        poseStartTime = 0
    }

    // MARK: - Private

    private func transition(to newState: ApproachState, now: CFTimeInterval) {
        state = newState
        stateEntryTime = now
    }

    private func resetToIdle(now: CFTimeInterval) {
        state = .idle
        stateEntryTime = now
        approachFrameCount = 0
    }

    private func makeDebugInfo() -> StateMachineDebugInfo {
        StateMachineDebugInfo(
            state: state,
            thresholds: thresholds,
            poseFramesProcessed: poseFramesProcessed,
            poseStartTime: poseStartTime
        )
    }
}
