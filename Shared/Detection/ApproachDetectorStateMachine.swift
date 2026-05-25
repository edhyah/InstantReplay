import CoreGraphics
import CoreMedia
import QuartzCore

enum ApproachState: String, Sendable {
    case idle = "IDLE"
    case approaching = "APPROACHING"
    case ascending = "ASCENDING"
    case descending = "DESCENDING"
}

struct StateMachineThresholds: Sendable, Equatable {
    let approachHorizontalVelocity: CGFloat
    let approachSustainedFrames: Int
    let approachMinDuration: TimeInterval
    let jumpSustainedFrames: Int
    let jumpMinVerticalDisplacement: CGFloat
    let ascendingVerticalVelocity: CGFloat // negative = upward in top-left origin coords
    let descendingVerticalVelocity: CGFloat // positive = downward
    let landingVerticalMagnitude: CGFloat
    let timeoutDuration: TimeInterval

    init(
        approachHorizontalVelocity: CGFloat = 0.28,
        approachSustainedFrames: Int = 2,
        approachMinDuration: TimeInterval = 0.3,
        jumpSustainedFrames: Int = 2,
        jumpMinVerticalDisplacement: CGFloat = 0.06,
        ascendingVerticalVelocity: CGFloat = -0.12,
        descendingVerticalVelocity: CGFloat = 0.15,
        landingVerticalMagnitude: CGFloat = 0.16,
        timeoutDuration: TimeInterval = 3.0
    ) {
        self.approachHorizontalVelocity = approachHorizontalVelocity
        self.approachSustainedFrames = approachSustainedFrames
        self.approachMinDuration = approachMinDuration
        self.jumpSustainedFrames = jumpSustainedFrames
        self.jumpMinVerticalDisplacement = jumpMinVerticalDisplacement
        self.ascendingVerticalVelocity = ascendingVerticalVelocity
        self.descendingVerticalVelocity = descendingVerticalVelocity
        self.landingVerticalMagnitude = landingVerticalMagnitude
        self.timeoutDuration = timeoutDuration
    }
}

struct StateMachineDebugInfo: Sendable {
    let state: ApproachState
    let thresholds: StateMachineThresholds
    let poseFramesProcessed: Int
    let poseStartTime: CFTimeInterval
}

final class ApproachDetectorStateMachine: Sendable {
    let thresholds: StateMachineThresholds
    private let timeProvider: TimeProvider

    private nonisolated(unsafe) var state: ApproachState = .idle
    private nonisolated(unsafe) var stateEntryTime: CFTimeInterval = 0
    private nonisolated(unsafe) var jumpFrameCount: Int = 0
    private nonisolated(unsafe) var jumpCandidateID: Int? = nil
    private nonisolated(unsafe) var jumpingBodyID: Int? = nil
    private nonisolated(unsafe) var pendingJumpTimestamp: CMTime?
    private nonisolated(unsafe) var jumpStartY: CGFloat?
    private nonisolated(unsafe) var hasEmittedJump: Bool = false
    private nonisolated(unsafe) var poseFramesProcessed: Int = 0
    private nonisolated(unsafe) var poseStartTime: CFTimeInterval = 0

    nonisolated(unsafe) var onMovementDetected: (@Sendable (MovementDetectionEvent) -> Void)?
    nonisolated(unsafe) var onStateTransition: ((ApproachState, CFTimeInterval) -> Void)?

    init(timeProvider: TimeProvider = SystemTimeProvider(), thresholds: StateMachineThresholds = StateMachineThresholds()) {
        self.timeProvider = timeProvider
        self.thresholds = thresholds
    }

    func step(trackedBodies: [TrackedBody], timestamp: CMTime) -> StateMachineDebugInfo {
        let now = timeProvider.currentTime()

        // Track pose FPS
        if poseStartTime == 0 {
            poseStartTime = now
        }
        poseFramesProcessed += 1

        // If all bodies disappear mid-jump, reset.
        guard !trackedBodies.isEmpty else {
            if state != .idle {
                resetToIdle(now: now)
            }
            return makeDebugInfo()
        }

        // Timeout: 3 seconds in any non-idle state without progression
        if state != .idle && (now - stateEntryTime) > thresholds.timeoutDuration {
            resetToIdle(now: now)
        }

        switch state {
        case .idle:
            if let candidate = upwardJumpCandidate(in: trackedBodies) {
                if jumpCandidateID == candidate.id {
                    jumpFrameCount += 1
                } else {
                    jumpCandidateID = candidate.id
                    jumpFrameCount = 1
                }

                if jumpFrameCount >= thresholds.jumpSustainedFrames {
                    jumpingBodyID = candidate.id
                    pendingJumpTimestamp = timestamp
                    jumpStartY = candidate.centroid.y
                    hasEmittedJump = false
                    transition(to: .ascending, now: now)
                }
            } else {
                jumpCandidateID = nil
                jumpFrameCount = 0
            }

        case .approaching:
            resetToIdle(now: now)

        case .ascending:
            guard let jumper = currentJumper(in: trackedBodies) else {
                resetToIdle(now: now)
                break
            }
            emitJumpIfConfirmed(jumper: jumper)
            if !hasEmittedJump && jumper.verticalVelocity >= 0 {
                resetToIdle(now: now)
                break
            }
            // Vertical velocity reversal — now moving downward past threshold
            if jumper.verticalVelocity > thresholds.descendingVerticalVelocity {
                transition(to: .descending, now: now)
            }

        case .descending:
            guard let jumper = currentJumper(in: trackedBodies) else {
                resetToIdle(now: now)
                break
            }
            // Vertical velocity magnitude drops below threshold — landed
            if abs(jumper.verticalVelocity) < thresholds.landingVerticalMagnitude {
                transition(to: .idle, now: now)
                jumpFrameCount = 0
                jumpCandidateID = nil
                jumpingBodyID = nil
                pendingJumpTimestamp = nil
                jumpStartY = nil
                hasEmittedJump = false
            }
        }

        return makeDebugInfo()
    }

    func step(dominantMover: TrackedBody?, timestamp: CMTime) -> StateMachineDebugInfo {
        step(trackedBodies: dominantMover.map { [$0] } ?? [], timestamp: timestamp)
    }

    func reset() {
        state = .idle
        stateEntryTime = 0
        jumpFrameCount = 0
        jumpCandidateID = nil
        jumpingBodyID = nil
        pendingJumpTimestamp = nil
        jumpStartY = nil
        hasEmittedJump = false
        poseFramesProcessed = 0
        poseStartTime = 0
    }

    // MARK: - Private

    private func transition(to newState: ApproachState, now: CFTimeInterval) {
        state = newState
        stateEntryTime = now
        onStateTransition?(newState, now)
    }

    private func resetToIdle(now: CFTimeInterval) {
        state = .idle
        stateEntryTime = now
        jumpFrameCount = 0
        jumpCandidateID = nil
        jumpingBodyID = nil
        pendingJumpTimestamp = nil
        jumpStartY = nil
        hasEmittedJump = false
    }

    private func upwardJumpCandidate(in trackedBodies: [TrackedBody]) -> TrackedBody? {
        trackedBodies
            .filter {
                $0.centroidHistory.count >= 2
                    && $0.verticalVelocity < thresholds.ascendingVerticalVelocity
            }
            .min(by: { $0.verticalVelocity < $1.verticalVelocity })
    }

    private func currentJumper(in trackedBodies: [TrackedBody]) -> TrackedBody? {
        guard let jumpingBodyID else { return nil }
        return trackedBodies.first { $0.id == jumpingBodyID }
    }

    private func emitJumpIfConfirmed(jumper: TrackedBody) {
        guard !hasEmittedJump,
              let pendingJumpTimestamp,
              let jumpStartY else {
            return
        }

        let upwardDisplacement = jumpStartY - jumper.centroid.y
        if upwardDisplacement >= thresholds.jumpMinVerticalDisplacement {
            hasEmittedJump = true
            onMovementDetected?(MovementDetectionEvent(jumpTimestamp: pendingJumpTimestamp))
        }
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
